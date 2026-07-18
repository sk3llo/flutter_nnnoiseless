use anyhow::{Context, Result};
use dasp::interpolate::sinc::Sinc;
use dasp::ring_buffer::Fixed;
use dasp::{signal, Signal};
use hound::{WavReader, WavSpec, WavWriter};
use nnnoiseless::{DenoiseState, RnnModel};
use once_cell::sync::Lazy;
use std::path::Path;
use std::sync::Mutex;

/// The fixed frame size required by the nnnoiseless model.
const FRAME_SIZE: usize = DenoiseState::FRAME_SIZE;
/// The target sample rate the model is trained for.
const TARGET_SAMPLE_RATE: u32 = 48000;

// This struct holds the state required for real-time processing.
struct DenoiseRealtimeState {
    // One denoiser for each channel. We'll assume mono for real-time.
    denoiser: Box<DenoiseState<'static>>,
    // Buffer for audio that has been resampled but not yet processed.
    resampled_buffer: Vec<f32>,
}

// Create a single, thread-safe, static instance of our state.
// This is crucial for FFI, as the state must persist across function calls.
static STATE: Lazy<Mutex<DenoiseRealtimeState>> = Lazy::new(|| {
    let model = RnnModel::default();
    // 'Leak' the model to give it a 'static lifetime. This is a safe and
    // common pattern for creating static state for FFI from non-static data.
    let static_model = Box::leak(Box::new(model));

    Mutex::new(DenoiseRealtimeState {
        denoiser: DenoiseState::with_model(static_model),
        resampled_buffer: Vec::new(),
    })
});

/// Denoises a chunk of raw audio bytes in real-time.
///
/// This function is stateful and designed to be called repeatedly with
/// consecutive chunks of audio data (e.g., from a microphone stream).
///
/// # Arguments
/// * `input` - A vector of bytes representing raw 16-bit PCM mono audio.
///
/// # Returns
/// A `Result` containing the denoised audio chunk as a `Vec<u8>`.
pub fn denoise_chunk(input: Vec<u8>, input_sample_rate: u32) -> Result<Vec<u8>> {
    // 1. Decode the input byte buffer into f32 samples.
    // The model expects audio in the i16 range, so we cast directly to f32.
    let input_samples: Vec<f32> = input
        .chunks_exact(2)
        .map(|chunk| i16::from_le_bytes(chunk.try_into().unwrap()) as f32)
        .collect();

    // 2. Resample the new audio chunk.
    let resampled_samples =
        if input_sample_rate != TARGET_SAMPLE_RATE {
        let signal = signal::from_iter(input_samples);
        let sinc = Sinc::new(Fixed::from([0.0; 256]));
        let resampler = signal.from_hz_to_hz(sinc, input_sample_rate as f64, TARGET_SAMPLE_RATE as f64);
        resampler.until_exhausted().collect::<Vec<f32>>()
    } else {
        input_samples
    };

    // 3. Lock the shared state and process the audio.
    let mut state = STATE.lock().unwrap();

    // Add the newly resampled audio to our persistent buffer.
    state.resampled_buffer.extend_from_slice(&resampled_samples);

    let mut output_bytes = Vec::new();

    // 4. Process all full frames available in the buffer.
    while state.resampled_buffer.len() >= FRAME_SIZE {
        // Drain the first FRAME_SIZE samples from the buffer to create an input frame.
        let input_frame: Vec<f32> = state.resampled_buffer.drain(0..FRAME_SIZE).collect();

        let mut output_frame = vec![0.0f32; FRAME_SIZE];
        state
            .denoiser
            .process_frame(&mut output_frame, &input_frame);

        // 5. Encode the cleaned frame back to bytes and add to the output.
        for sample in output_frame {
            let clipped_sample = sample.max(i16::MIN as f32).min(i16::MAX as f32);
            output_bytes.extend_from_slice(&(clipped_sample as i16).to_le_bytes());
        }
    }

    // Any remaining samples in `state.resampled_buffer` are carried over to the next call.
    Ok(output_bytes)
}

/// Reads all samples from a WAV file as f32 in the i16 range, regardless of
/// the underlying sample format (16/24/32-bit int or 32-bit float).
fn read_samples_interleaved(reader: &mut WavReader<std::io::BufReader<std::fs::File>>) -> Result<Vec<f32>> {
    let spec = reader.spec();
    match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Int, 16) => reader
            .samples::<i16>()
            .map(|s| s.map(|v| v as f32).map_err(Into::into))
            .collect(),
        (hound::SampleFormat::Int, bits @ 17..=32) => {
            // Scale down to the i16 range the model expects.
            let shift = bits - 16;
            reader
                .samples::<i32>()
                .map(|s| s.map(|v| (v >> shift) as f32).map_err(Into::into))
                .collect()
        }
        (hound::SampleFormat::Float, 32) => reader
            .samples::<f32>()
            .map(|s| s.map(|v| v * 32767.0).map_err(Into::into))
            .collect(),
        (format, bits) => anyhow::bail!(
            "Unsupported WAV format: {bits}-bit {format:?}. \
             Supported: 16/24/32-bit int and 32-bit float."
        ),
    }
}

// The file-based denoising function.
fn denoise_wav(input_path: &Path, output_path: &Path) -> Result<()> {
    let mut reader = WavReader::open(input_path)
        .with_context(|| format!("Failed to open input file: {:?}", input_path))?;
    let spec = reader.spec();

    let input_samples_interleaved = read_samples_interleaved(&mut reader)
        .with_context(|| format!("Failed to read samples from: {:?}", input_path))?;

    if input_samples_interleaved.is_empty() {
        anyhow::bail!("Input file is empty.");
    }

    let num_channels = spec.channels as usize;

    let mut channel_buffers: Vec<Vec<f32>> =
        vec![Vec::with_capacity(input_samples_interleaved.len() / num_channels); num_channels];
    for (i, sample) in input_samples_interleaved.iter().enumerate() {
        channel_buffers[i % num_channels].push(*sample);
    }

    let resampled_channels = if spec.sample_rate != TARGET_SAMPLE_RATE {
        channel_buffers
            .into_iter()
            .map(|channel_data| {
                let signal = signal::from_iter(channel_data);
                let sinc = Sinc::new(Fixed::from([0.0; 256]));
                let resampler =
                    signal.from_hz_to_hz(sinc, spec.sample_rate as f64, TARGET_SAMPLE_RATE as f64);
                resampler.until_exhausted().collect::<Vec<f32>>()
            })
            .collect()
    } else {
        channel_buffers
    };

    let model = RnnModel::default();
    let mut denoisers: Vec<Box<DenoiseState>> = (0..num_channels)
        .map(|_| DenoiseState::with_model(&model))
        .collect();

    let num_samples_per_channel = resampled_channels.first().map_or(0, |c| c.len());
    let mut cleaned_channels: Vec<Vec<f32>> =
        vec![Vec::with_capacity(num_samples_per_channel); num_channels];

    for frame_start in (0..num_samples_per_channel).step_by(FRAME_SIZE) {
        for ch in 0..num_channels {
            let frame_end = (frame_start + FRAME_SIZE).min(num_samples_per_channel);
            let input_slice = &resampled_channels[ch][frame_start..frame_end];

            let mut input_frame = vec![0.0f32; FRAME_SIZE];
            input_frame[..input_slice.len()].copy_from_slice(input_slice);

            let mut output_frame = vec![0.0f32; FRAME_SIZE];
            denoisers[ch].process_frame(&mut output_frame, &input_frame);

            let output_len = frame_end - frame_start;
            cleaned_channels[ch].extend_from_slice(&output_frame[..output_len]);
        }
    }

    // Resample back to the original rate so the output file matches the input.
    let cleaned_channels: Vec<Vec<f32>> = if spec.sample_rate != TARGET_SAMPLE_RATE {
        cleaned_channels
            .into_iter()
            .map(|channel_data| {
                let signal = signal::from_iter(channel_data);
                let sinc = Sinc::new(Fixed::from([0.0; 256]));
                let resampler =
                    signal.from_hz_to_hz(sinc, TARGET_SAMPLE_RATE as f64, spec.sample_rate as f64);
                resampler.until_exhausted().collect::<Vec<f32>>()
            })
            .collect()
    } else {
        cleaned_channels
    };

    let mut output_samples_interleaved = vec![0.0f32; cleaned_channels[0].len() * num_channels];
    for i in 0..cleaned_channels[0].len() {
        for ch in 0..num_channels {
            output_samples_interleaved[i * num_channels + ch] = cleaned_channels[ch][i];
        }
    }

    let output_spec = WavSpec {
        channels: spec.channels,
        sample_rate: spec.sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = WavWriter::create(output_path, output_spec)?;
    for sample in output_samples_interleaved {
        let clipped_sample = sample.max(i16::MIN as f32).min(i16::MAX as f32);
        writer.write_sample(clipped_sample as i16)?;
    }
    writer.finalize()?;

    Ok(())
}


// Wrapper function for file-based denoising.
pub fn denoise(input_path_str: &String, output_path_str: &String) -> Result<()> {
    let input_path = Path::new(input_path_str);
    let output_path = Path::new(output_path_str);
    denoise_wav(input_path, output_path)
}
