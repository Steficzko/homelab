#!/usr/bin/env python3
"""
CPU Whisper server — OpenAI-compatible /v1/audio/transcriptions API.
Backend: faster-whisper (CTranslate2 int8) + pyannote.audio diarization.

Env vars:
  WHISPER_MODEL          default: large-v3
  HF_TOKEN               required for diarization
  WHISPER_DIARIZATION    set to "true" to enable speaker labels
  PORT                   default: 8000
"""
import os
import tempfile
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse
from faster_whisper import WhisperModel

MODEL_NAME = os.environ.get("WHISPER_MODEL", "large-v3")
HF_TOKEN   = os.environ.get("HF_TOKEN", "")
DIARIZE    = os.environ.get("WHISPER_DIARIZATION", "false").lower() == "true" and bool(HF_TOKEN)
PORT       = int(os.environ.get("PORT", 8000))

app = FastAPI()

print(f"[whisper-cpu] loading {MODEL_NAME} on cpu int8 ...")
_model = WhisperModel(MODEL_NAME, device="cpu", compute_type="int8")
print("[whisper-cpu] model ready")

_diarize_pipeline = None
if DIARIZE:
    import torch
    from pyannote.audio import Pipeline
    print("[whisper-cpu] loading pyannote diarization pipeline ...")
    _diarize_pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        token=HF_TOKEN,
    )
    print("[whisper-cpu] diarization pipeline ready")


def _strip_tail_repetitions(segments: list) -> list:
    """Remove repeated trailing segments — classic Whisper hallucination on silence."""
    if len(segments) < 3:
        return segments
    texts = [s["text"].strip() for s in segments]
    # Walk backwards: drop segments that repeat the same text 3+ times in a row
    tail = texts[-1]
    count = 0
    for t in reversed(texts):
        if t == tail:
            count += 1
        else:
            break
    if count >= 3:
        segments = segments[: len(segments) - count]
    return segments


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME, "device": "cpu", "diarization": DIARIZE}


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file:            UploadFile = File(...),
    model:           str  = Form(default="large-v3"),
    response_format: str  = Form(default="json"),
    language:        str  = Form(default=None),
    vad_filter:      bool = Form(default=True),
):
    ext = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    try:
        segments_gen, info = _model.transcribe(
            tmp_path,
            language=language or None,
            vad_filter=vad_filter,
            vad_parameters={"threshold": 0.6, "min_silence_duration_ms": 500},
            condition_on_previous_text=False,
            compression_ratio_threshold=2.4,
            no_speech_threshold=0.6,
            word_timestamps=False,
        )

        segments = [
            {"id": i, "start": s.start, "end": s.end, "text": s.text}
            for i, s in enumerate(segments_gen)
        ]

        segments = _strip_tail_repetitions(segments)

        if _diarize_pipeline is not None:
            import torch, torchaudio
            waveform, sample_rate = torchaudio.load(tmp_path)
            diarization_output = _diarize_pipeline({"waveform": waveform, "sample_rate": sample_rate})
            # pyannote 4.x returns DiarizeOutput with .diarization attribute; 3.x returns Annotation directly
            annotation = getattr(diarization_output, "diarization", diarization_output)
            for turn, _, speaker in annotation.itertracks(yield_label=True):
                for seg in segments:
                    mid = (seg["start"] + seg["end"]) / 2
                    if turn.start <= mid <= turn.end and "speaker" not in seg:
                        seg["speaker"] = speaker

        if response_format == "verbose_json":
            duration = segments[-1]["end"] if segments else 0
            return {
                "task": "transcribe",
                "language": info.language,
                "duration": duration,
                "text": " ".join(s["text"] for s in segments),
                "segments": segments,
            }
        return {"text": " ".join(s["text"] for s in segments)}

    finally:
        os.unlink(tmp_path)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
