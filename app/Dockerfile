FROM python:3.12-slim

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev && rm -rf /var/lib/apt/lists/*

# CPU-only PyTorch first. The default torch now pulls ~6 GB of NVIDIA CUDA packages on ARM,
# which fills the EC2 disk; this instance has no GPU anyway.
RUN pip install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

RUN python -c "from sentence_transformers import SentenceTransformer; SentenceTransformer('all-MiniLM-L6-v2')"

ENV HF_HUB_OFFLINE=1

COPY app/ ./app/
COPY index.html ./index.html

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
