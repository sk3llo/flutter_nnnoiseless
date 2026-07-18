use anyhow::{ensure, Context, Result};
use flutter_rust_bridge::frb;
use nnnoiseless::{DenoiseState, RnnModel};
use rubato::{FastFixedIn, PolynomialDegree, Resampler};

/// The fixed frame size required by the nnnoiseless model (480 samples = 10ms).
const FRAME_SIZE: usize = DenoiseState::FRAME_SIZE;
/// The sample rate the RNNoise model is trained for.
const TARGET_SAMPLE_RATE: u32 = 48000;
/// Fixed input size fed to the streaming resamplers.
const RESAMPLER_CHUNK: usize = 1024;
/// Upper bound on interleaved channels per session.
const MAX_CHANNELS: usize = 8;

/// The result of processing one chunk of audio through a [DenoiseSession].
pub struct DenoiseOutput {
    /// Denoised 16-bit PCM audio at the session's sample rate, interleaved
    /// with the session's channel count.
    ///
    /// May be empty (or shorter/longer than the input) while the session
    /// buffers samples towards full 10ms frames; timing evens out across
    /// consecutive calls.
    pub audio: Vec<u8>,
    /// Voice activity probability (0.0..=1.0) for each 10ms frame that was
    /// processed during this call, in order. For multi-channel sessions this
    /// is the maximum across channels for that frame.
    pub voice_probabilities: Vec<f32>,
}

/// A stateful, instance-based denoiser for one audio stream.
///
/// Unlike the legacy global `denoise_chunk`, each session owns its own
/// RNNoise state and streaming resamplers, so multiple sessions can run
/// concurrently and state never leaks between recordings.
#[frb(opaque)]
pub struct DenoiseSession {
    denoisers: Vec<Box<DenoiseState<'static>>>,
    model: Option<RnnModel>,
    channels: usize,
    wet: f32,
    frames_processed: u64,
    resampler_in: Option<FastFixedIn<f32>>,
    resampler_out: Option<FastFixedIn<f32>>,
    /// A byte held over when a chunk contained an odd number of bytes, so
    /// 16-bit sample pairs survive arbitrary byte-level splits.
    byte_carry: Option<u8>,
    /// Interleaved samples left over when a chunk did not contain a whole
    /// number of sample frames, kept so channel alignment survives arbitrary
    /// chunk sizes.
    sample_carry: Vec<f32>,
    /// Per-channel samples at the input rate waiting for a full resampler chunk.
    pending_in: Vec<Vec<f32>>,
    /// Per-channel samples at 48kHz waiting for a full 480-sample frame.
    buffer_48k: Vec<Vec<f32>>,
    /// Per-channel denoised samples at 48kHz waiting for a full resampler chunk.
    pending_out_48k: Vec<Vec<f32>>,
}

impl DenoiseSession {
    /// Creates a new denoising session.
    ///
    /// * `sample_rate` - sample rate of the PCM data passed to [process].
    ///   Output audio is returned at the same rate.
    /// * `wet` - dry/wet mix: 1.0 = fully denoised, 0.0 = passthrough.
    /// * `channels` - number of interleaved channels in the PCM data. Each
    ///   channel is denoised independently.
    /// * `model` - optional custom RNNoise model in the nnnoiseless training
    ///   format; `None` uses the built-in general-purpose model.
    ///
    /// Deliberately not `#[frb(sync)]`: model parsing and per-channel state
    /// construction should run on the worker pool, not the UI thread.
    pub fn create(
        sample_rate: u32,
        wet: f32,
        channels: u32,
        model: Option<Vec<u8>>,
    ) -> Result<DenoiseSession> {
        ensure!(
            (8000..=192_000).contains(&sample_rate),
            "sample_rate must be between 8000 and 192000, got {sample_rate}"
        );
        ensure!(
            (0.0..=1.0).contains(&wet),
            "wet must be between 0.0 and 1.0, got {wet}"
        );
        let channels = channels as usize;
        ensure!(
            (1..=MAX_CHANNELS).contains(&channels),
            "channels must be between 1 and {MAX_CHANNELS}, got {channels}"
        );

        let model = match model {
            Some(bytes) => Some(
                RnnModel::from_bytes(&bytes)
                    .context("Invalid RNNoise model data (expected nnnoiseless training format)")?,
            ),
            None => None,
        };

        let (resampler_in, resampler_out) = if sample_rate != TARGET_SAMPLE_RATE {
            let up = FastFixedIn::new(
                TARGET_SAMPLE_RATE as f64 / sample_rate as f64,
                1.0,
                PolynomialDegree::Septic,
                RESAMPLER_CHUNK,
                channels,
            )?;
            let down = FastFixedIn::new(
                sample_rate as f64 / TARGET_SAMPLE_RATE as f64,
                1.0,
                PolynomialDegree::Septic,
                RESAMPLER_CHUNK,
                channels,
            )?;
            (Some(up), Some(down))
        } else {
            (None, None)
        };

        Ok(DenoiseSession {
            denoisers: (0..channels).map(|_| make_denoiser(&model)).collect(),
            model,
            channels,
            wet,
            frames_processed: 0,
            resampler_in,
            resampler_out,
            byte_carry: None,
            sample_carry: Vec::new(),
            pending_in: vec![Vec::new(); channels],
            buffer_48k: vec![Vec::new(); channels],
            pending_out_48k: vec![Vec::new(); channels],
        })
    }

    /// Denoises a chunk of raw 16-bit PCM audio (interleaved if the session
    /// has more than one channel).
    ///
    /// Designed to be called repeatedly with consecutive chunks (e.g. from a
    /// microphone stream). Samples are buffered internally, so the returned
    /// audio length may differ from the input length on any single call.
    pub fn process(&mut self, input: Vec<u8>) -> Result<DenoiseOutput> {
        // Re-attach a byte held over from a previous odd-length chunk so
        // 16-bit sample pairs survive arbitrary byte-level splits.
        let mut bytes = match self.byte_carry.take() {
            Some(carry) => {
                let mut joined = Vec::with_capacity(input.len() + 1);
                joined.push(carry);
                joined.extend_from_slice(&input);
                joined
            }
            None => input,
        };
        if bytes.len() % 2 != 0 {
            self.byte_carry = bytes.pop();
        }

        let mut samples: Vec<f32> = std::mem::take(&mut self.sample_carry);
        samples.extend(
            bytes
                .chunks_exact(2)
                .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32),
        );
        // Hold back samples that do not form a whole interleaved frame so
        // channel alignment survives arbitrary chunk sizes.
        let complete = samples.len() - samples.len() % self.channels;
        self.sample_carry = samples.split_off(complete);

        let mut per_channel = vec![Vec::with_capacity(samples.len() / self.channels); self.channels];
        for (i, sample) in samples.into_iter().enumerate() {
            per_channel[i % self.channels].push(sample);
        }

        self.resample_in(per_channel)?;
        let (denoised, voice_probabilities) = self.denoise_frames();
        let audio = self.resample_out(denoised)?;

        Ok(DenoiseOutput {
            audio: interleave_to_pcm16(&audio),
            voice_probabilities,
        })
    }

    /// Drains any internally buffered audio, padding with silence as needed.
    ///
    /// Call once at the end of a stream to receive the tail of the audio.
    pub fn flush(&mut self) -> Result<Vec<u8>> {
        self.byte_carry = None;
        self.sample_carry.clear();
        // Push the partial resampler chunk through with zero padding.
        if self.resampler_in.is_some() && !self.pending_in[0].is_empty() {
            for pending in &mut self.pending_in {
                pending.resize(RESAMPLER_CHUNK, 0.0);
            }
            let pending =
                std::mem::replace(&mut self.pending_in, vec![Vec::new(); self.channels]);
            self.resample_in(pending)?;
        }
        // Pad the 48k buffers to a full frame.
        if !self.buffer_48k[0].is_empty() {
            let padded = self.buffer_48k[0].len().div_ceil(FRAME_SIZE) * FRAME_SIZE;
            for buffer in &mut self.buffer_48k {
                buffer.resize(padded, 0.0);
            }
        }
        let (denoised, _) = self.denoise_frames();
        let mut audio = self.resample_out(denoised)?;
        // Push the partial output chunk through with zero padding.
        if self.resampler_out.is_some() && !self.pending_out_48k[0].is_empty() {
            for pending in &mut self.pending_out_48k {
                pending.resize(RESAMPLER_CHUNK, 0.0);
            }
            let pending =
                std::mem::replace(&mut self.pending_out_48k, vec![Vec::new(); self.channels]);
            let tail = self.resample_out(pending)?;
            for (ch, data) in tail.into_iter().enumerate() {
                audio[ch].extend(data);
            }
        }
        Ok(interleave_to_pcm16(&audio))
    }

    /// Clears all internal state so the session can be reused for a new
    /// stream without artifacts from the previous one.
    pub fn reset(&mut self) {
        self.denoisers = (0..self.channels)
            .map(|_| make_denoiser(&self.model))
            .collect();
        self.frames_processed = 0;
        self.byte_carry = None;
        self.sample_carry.clear();
        for buffer in self
            .pending_in
            .iter_mut()
            .chain(&mut self.buffer_48k)
            .chain(&mut self.pending_out_48k)
        {
            buffer.clear();
        }
        if let Some(r) = &mut self.resampler_in {
            r.reset();
        }
        if let Some(r) = &mut self.resampler_out {
            r.reset();
        }
    }

    /// Resamples per-channel input-rate samples to 48kHz into `buffer_48k`.
    fn resample_in(&mut self, per_channel: Vec<Vec<f32>>) -> Result<()> {
        match &mut self.resampler_in {
            Some(resampler) => {
                for (ch, data) in per_channel.into_iter().enumerate() {
                    self.pending_in[ch].extend(data);
                }
                while self.pending_in[0].len() >= RESAMPLER_CHUNK {
                    let chunks: Vec<Vec<f32>> = self
                        .pending_in
                        .iter_mut()
                        .map(|pending| pending.drain(..RESAMPLER_CHUNK).collect())
                        .collect();
                    let out = resampler.process(&chunks, None)?;
                    for (ch, data) in out.into_iter().enumerate() {
                        self.buffer_48k[ch].extend(data);
                    }
                }
            }
            None => {
                for (ch, data) in per_channel.into_iter().enumerate() {
                    self.buffer_48k[ch].extend(data);
                }
            }
        }
        Ok(())
    }

    /// Runs all complete 480-sample frames in `buffer_48k` through RNNoise.
    fn denoise_frames(&mut self) -> (Vec<Vec<f32>>, Vec<f32>) {
        let mut denoised = vec![Vec::new(); self.channels];
        let mut vads = Vec::new();
        while self.buffer_48k[0].len() >= FRAME_SIZE {
            let mut frame_vad = 0.0f32;
            for ((denoiser, buffer), denoised_ch) in self
                .denoisers
                .iter_mut()
                .zip(&mut self.buffer_48k)
                .zip(&mut denoised)
            {
                let frame: Vec<f32> = buffer.drain(..FRAME_SIZE).collect();
                let mut out = vec![0.0f32; FRAME_SIZE];
                let vad = denoiser.process_frame(&mut out, &frame);
                if self.frames_processed == 0 {
                    // RNNoise's first frame is a warm-up frame; silence it
                    // instead of dropping it so stream timing is preserved.
                    out.fill(0.0);
                } else if self.wet < 1.0 {
                    for (o, i) in out.iter_mut().zip(&frame) {
                        *o = self.wet * *o + (1.0 - self.wet) * i;
                    }
                }
                frame_vad = frame_vad.max(vad);
                denoised_ch.extend(out);
            }
            vads.push(frame_vad);
            self.frames_processed += 1;
        }
        (denoised, vads)
    }

    /// Resamples per-channel denoised 48kHz samples back to the input rate.
    fn resample_out(&mut self, per_channel: Vec<Vec<f32>>) -> Result<Vec<Vec<f32>>> {
        match &mut self.resampler_out {
            Some(resampler) => {
                for (ch, data) in per_channel.into_iter().enumerate() {
                    self.pending_out_48k[ch].extend(data);
                }
                let mut out = vec![Vec::new(); self.channels];
                while self.pending_out_48k[0].len() >= RESAMPLER_CHUNK {
                    let chunks: Vec<Vec<f32>> = self
                        .pending_out_48k
                        .iter_mut()
                        .map(|pending| pending.drain(..RESAMPLER_CHUNK).collect())
                        .collect();
                    let resampled = resampler.process(&chunks, None)?;
                    for (ch, data) in resampled.into_iter().enumerate() {
                        out[ch].extend(data);
                    }
                }
                Ok(out)
            }
            None => Ok(per_channel),
        }
    }
}

/// Builds a denoiser from the custom model when one is set, or the built-in
/// model otherwise.
fn make_denoiser(model: &Option<RnnModel>) -> Box<DenoiseState<'static>> {
    match model {
        Some(m) => DenoiseState::from_model(m.clone()),
        None => DenoiseState::new(),
    }
}

/// Interleaves per-channel i16-range f32 samples into 16-bit LE PCM bytes.
fn interleave_to_pcm16(channels: &[Vec<f32>]) -> Vec<u8> {
    let frames = channels.first().map_or(0, |c| c.len());
    let mut bytes = Vec::with_capacity(frames * channels.len() * 2);
    for i in 0..frames {
        for channel in channels {
            let clipped = channel[i].max(i16::MIN as f32).min(i16::MAX as f32);
            bytes.extend_from_slice(&(clipped as i16).to_le_bytes());
        }
    }
    bytes
}
