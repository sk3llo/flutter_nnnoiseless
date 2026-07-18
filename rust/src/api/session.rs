use anyhow::{ensure, Result};
use flutter_rust_bridge::frb;
use nnnoiseless::DenoiseState;
use rubato::{FastFixedIn, PolynomialDegree, Resampler};

/// The fixed frame size required by the nnnoiseless model (480 samples = 10ms).
const FRAME_SIZE: usize = DenoiseState::FRAME_SIZE;
/// The sample rate the RNNoise model is trained for.
const TARGET_SAMPLE_RATE: u32 = 48000;
/// Fixed input size fed to the streaming resamplers.
const RESAMPLER_CHUNK: usize = 1024;

/// The result of processing one chunk of audio through a [DenoiseSession].
pub struct DenoiseOutput {
    /// Denoised 16-bit PCM mono audio at the session's sample rate.
    ///
    /// May be empty (or shorter/longer than the input) while the session
    /// buffers samples towards full 10ms frames; timing evens out across
    /// consecutive calls.
    pub audio: Vec<u8>,
    /// Voice activity probability (0.0..=1.0) for each 10ms frame that was
    /// processed during this call, in order.
    pub voice_probabilities: Vec<f32>,
}

/// A stateful, instance-based denoiser for one mono audio stream.
///
/// Unlike the legacy global `denoise_chunk`, each session owns its own
/// RNNoise state and streaming resamplers, so multiple sessions can run
/// concurrently and state never leaks between recordings.
#[frb(opaque)]
pub struct DenoiseSession {
    denoiser: Box<DenoiseState<'static>>,
    wet: f32,
    frames_processed: u64,
    resampler_in: Option<FastFixedIn<f32>>,
    resampler_out: Option<FastFixedIn<f32>>,
    /// Samples at the input rate waiting for a full resampler chunk.
    pending_in: Vec<f32>,
    /// Samples at 48kHz waiting for a full 480-sample frame.
    buffer_48k: Vec<f32>,
    /// Denoised samples at 48kHz waiting for a full resampler chunk.
    pending_out_48k: Vec<f32>,
}

impl DenoiseSession {
    /// Creates a new denoising session.
    ///
    /// * `sample_rate` - sample rate of the PCM data passed to [process].
    ///   Output audio is returned at the same rate.
    /// * `wet` - dry/wet mix: 1.0 = fully denoised, 0.0 = passthrough.
    #[frb(sync)]
    pub fn create(sample_rate: u32, wet: f32) -> Result<DenoiseSession> {
        ensure!(
            (8000..=192_000).contains(&sample_rate),
            "sample_rate must be between 8000 and 192000, got {sample_rate}"
        );
        ensure!(
            (0.0..=1.0).contains(&wet),
            "wet must be between 0.0 and 1.0, got {wet}"
        );

        let (resampler_in, resampler_out) = if sample_rate != TARGET_SAMPLE_RATE {
            let up = FastFixedIn::new(
                TARGET_SAMPLE_RATE as f64 / sample_rate as f64,
                1.0,
                PolynomialDegree::Septic,
                RESAMPLER_CHUNK,
                1,
            )?;
            let down = FastFixedIn::new(
                sample_rate as f64 / TARGET_SAMPLE_RATE as f64,
                1.0,
                PolynomialDegree::Septic,
                RESAMPLER_CHUNK,
                1,
            )?;
            (Some(up), Some(down))
        } else {
            (None, None)
        };

        Ok(DenoiseSession {
            denoiser: DenoiseState::new(),
            wet,
            frames_processed: 0,
            resampler_in,
            resampler_out,
            pending_in: Vec::new(),
            buffer_48k: Vec::new(),
            pending_out_48k: Vec::new(),
        })
    }

    /// Denoises a chunk of raw 16-bit PCM mono audio.
    ///
    /// Designed to be called repeatedly with consecutive chunks (e.g. from a
    /// microphone stream). Samples are buffered internally, so the returned
    /// audio length may differ from the input length on any single call.
    pub fn process(&mut self, input: Vec<u8>) -> Result<DenoiseOutput> {
        let samples: Vec<f32> = input
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32)
            .collect();

        self.resample_in(samples)?;
        let (denoised, voice_probabilities) = self.denoise_frames();
        let audio = self.resample_out(denoised)?;

        Ok(DenoiseOutput {
            audio: to_pcm16(&audio),
            voice_probabilities,
        })
    }

    /// Drains any internally buffered audio, padding with silence as needed.
    ///
    /// Call once at the end of a stream to receive the tail of the audio.
    pub fn flush(&mut self) -> Result<Vec<u8>> {
        // Push the partial resampler chunk through with zero padding.
        if self.resampler_in.is_some() && !self.pending_in.is_empty() {
            self.pending_in.resize(RESAMPLER_CHUNK, 0.0);
            let pending = std::mem::take(&mut self.pending_in);
            self.resample_in(pending)?;
        }
        // Pad the 48k buffer to a full frame.
        if !self.buffer_48k.is_empty() {
            let padded = self.buffer_48k.len().div_ceil(FRAME_SIZE) * FRAME_SIZE;
            self.buffer_48k.resize(padded, 0.0);
        }
        let (denoised, _) = self.denoise_frames();
        let mut audio = self.resample_out(denoised)?;
        // Push the partial output chunk through with zero padding.
        if self.resampler_out.is_some() && !self.pending_out_48k.is_empty() {
            self.pending_out_48k.resize(RESAMPLER_CHUNK, 0.0);
            let pending = std::mem::take(&mut self.pending_out_48k);
            audio.extend(self.resample_out(pending)?);
        }
        Ok(to_pcm16(&audio))
    }

    /// Clears all internal state so the session can be reused for a new
    /// stream without artifacts from the previous one.
    pub fn reset(&mut self) {
        self.denoiser = DenoiseState::new();
        self.frames_processed = 0;
        self.pending_in.clear();
        self.buffer_48k.clear();
        self.pending_out_48k.clear();
        if let Some(r) = &mut self.resampler_in {
            r.reset();
        }
        if let Some(r) = &mut self.resampler_out {
            r.reset();
        }
    }

    /// Resamples input-rate samples to 48kHz into `buffer_48k`.
    fn resample_in(&mut self, samples: Vec<f32>) -> Result<()> {
        match &mut self.resampler_in {
            Some(resampler) => {
                self.pending_in.extend(samples);
                while self.pending_in.len() >= RESAMPLER_CHUNK {
                    let chunk: Vec<f32> = self.pending_in.drain(..RESAMPLER_CHUNK).collect();
                    let out = resampler.process(&[chunk], None)?;
                    self.buffer_48k.extend(&out[0]);
                }
            }
            None => self.buffer_48k.extend(samples),
        }
        Ok(())
    }

    /// Runs all complete 480-sample frames in `buffer_48k` through RNNoise.
    fn denoise_frames(&mut self) -> (Vec<f32>, Vec<f32>) {
        let mut denoised = Vec::new();
        let mut vads = Vec::new();
        while self.buffer_48k.len() >= FRAME_SIZE {
            let frame: Vec<f32> = self.buffer_48k.drain(..FRAME_SIZE).collect();
            let mut out = vec![0.0f32; FRAME_SIZE];
            let vad = self.denoiser.process_frame(&mut out, &frame);
            if self.frames_processed == 0 {
                // RNNoise's first frame is a warm-up frame; silence it instead
                // of dropping it so stream timing is preserved.
                out.fill(0.0);
            } else if self.wet < 1.0 {
                for (o, i) in out.iter_mut().zip(&frame) {
                    *o = self.wet * *o + (1.0 - self.wet) * i;
                }
            }
            vads.push(vad);
            denoised.extend(out);
            self.frames_processed += 1;
        }
        (denoised, vads)
    }

    /// Resamples denoised 48kHz samples back to the input rate.
    fn resample_out(&mut self, samples: Vec<f32>) -> Result<Vec<f32>> {
        match &mut self.resampler_out {
            Some(resampler) => {
                self.pending_out_48k.extend(samples);
                let mut out = Vec::new();
                while self.pending_out_48k.len() >= RESAMPLER_CHUNK {
                    let chunk: Vec<f32> = self.pending_out_48k.drain(..RESAMPLER_CHUNK).collect();
                    out.extend(&resampler.process(&[chunk], None)?[0]);
                }
                Ok(out)
            }
            None => Ok(samples),
        }
    }
}

/// Converts i16-range f32 samples to 16-bit little-endian PCM bytes.
fn to_pcm16(samples: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        let clipped = sample.max(i16::MIN as f32).min(i16::MAX as f32);
        bytes.extend_from_slice(&(clipped as i16).to_le_bytes());
    }
    bytes
}
