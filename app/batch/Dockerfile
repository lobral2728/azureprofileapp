FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY batch.py ./batch.py
# Put your model here before building (or mount at runtime)
COPY model/ ./model/

CMD ["python", "batch.py"]
