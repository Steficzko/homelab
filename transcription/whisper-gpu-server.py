#!/usr/bin/env python3
"""
GPU Whisper server — OpenAI-compatible /v1/audio/transcriptions API.
Backend: openai-whisper (PyTorch, ROCm/CUDA) + pyannote.audio diarization.

Env vars:
  WHISPER_MODEL          default: large-v3
  HF_TOKEN               required for diarization
  WHISPER_DIARIZATION    set to "true" to enable speaker labels (needs HF_TOKEN)
  PORT                   default: 8000
"""
import os
import tempfile
import torch
import whisper
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from fastapi.responses import JSONResponse

MODEL_NAME  = os.environ.get("WHISPER_MODEL", "large-v3")
HF_TOKEN    = os.environ.get("HF_TOKEN", "")
DIARIZE     = os.environ.get("WHISPER_DIARIZATION", "false").lower() == "true" and bool(HF_TOKEN)
PORT        = int(os.environ.get("PORT", 8000))

app = FastAPI()

# ROCm exposes itself as "cuda" through the HIP compatibility layer
device = "cuda" if torch.cuda.is_available() else "cpu"
print(f"[whisper-gpu] device={device}  model={MODEL_NAME}  diarize={DIARIZE}")

print(f"[whisper-gpu] loading {MODEL_NAME}...")
_model = whisper.load_model(MODEL_NAME, device=device)
print("[whisper-gpu] model ready")

_diarize_pipeline = None
if DIARIZE:
    from pyannote.audio import Pipeline
    print("[whisper-gpu] loading pyannote diarization pipeline...")
    _diarize_pipeline = Pipeline.from_pretrained(
        "pyannote/speaker-diarization-3.1",
        use_auth_token=HF_TOKEN,
    )
    if device == "cuda":
        _diarize_pipeline.to(torch.device("cuda"))
    print("[whisper-gpu] diarization pipeline ready")


@app.get("/health")
def health():
    return {"status": "ok", "model": MODEL_NAME, "device": device, "diarization": DIARIZE}


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    model: str = Form(default="whisper-1"),
    response_format: str = Form(default="json"),
    language: str = Form(default=None),
):
    ext = os.path.splitext(file.filename or "audio.wav")[1] or ".wav"
    with tempfile.NamedTemporaryFile(suffix=ext, delete=False) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    try:
        result = _model.transcribe(
            tmp_path,
            language=language or None,
            verbose=False,
            task="transcribe",
            word_timestamps=True,
        )

        segments = [
            {"id": s["id"], "start": s["start"], "end": s["end"], "text": s["text"]}
            for s in result["segments"]
        ]

        if _diarize_pipeline is not None:
            import torchaudio
            waveform, sample_rate = torchaudio.load(tmp_path)
            diarization = _diarize_pipeline({"waveform": waveform, "sample_rate": sample_rate})
            for turn, _, speaker in diarization.itertracks(yield_label=True):
                for seg in segments:
                    mid = (seg["start"] + seg["end"]) / 2
                    if turn.start <= mid <= turn.end and "speaker" not in seg:
                        seg["speaker"] = speaker

        if response_format == "verbose_json":
            return {
                "task": "transcribe",
                "language": result.get("language", ""),
                "duration": result["segments"][-1]["end"] if result["segments"] else 0,
                "text": result["text"],
                "segments": segments,
            }
        return {"text": result["text"]}

    finally:
        os.unlink(tmp_path)


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=PORT)
