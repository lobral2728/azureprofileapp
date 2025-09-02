from fastapi import FastAPI, HTTPException
from fastapi.responses import StreamingResponse
from typing import List, Literal, Optional
import io, json, os
import requests
from azure.identity import ManagedIdentityCredential, DefaultAzureCredential
from azure.storage.blob import BlobServiceClient
from azure.data.tables import TableServiceClient

app = FastAPI(title="GrinBin Profile Pic API")

# Config via env
STORAGE_ACCOUNT = os.getenv("STORAGE_ACCOUNT")
PRED_CONTAINER  = os.getenv("PRED_CONTAINER", "predictions")
CACHE_CONTAINER = os.getenv("CACHE_CONTAINER", "profilepics-cache")
TABLE_LABELS    = os.getenv("TABLE_LABELS", "labels")
MIN_CONF        = float(os.getenv("MIN_CONF", "0.95"))
LOW_CONF        = float(os.getenv("LOW_CONF", "0.70"))

# Auth
cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
msi = ManagedIdentityCredential()  # used specifically for Graph calls

blob = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT}.blob.core.windows.net",
    credential=cred
)
table = TableServiceClient(
    endpoint=f"https://{STORAGE_ACCOUNT}.table.core.windows.net/",
    credential=cred
)

def graph_token() -> str:
    return msi.get_token("https://graph.microsoft.com/.default").token

def list_runs() -> List[str]:
    # list "folders" under predictions/
    container = blob.get_container_client(PRED_CONTAINER)
    seen = set()
    for b in container.list_blobs():
        # expect paths like "<run_id>/predictions.jsonl"
        parts = b.name.split("/", 1)
        if len(parts) == 2:
            seen.add(parts[0])
    return sorted(seen, reverse=True)

def read_predictions(run_id: str) -> List[dict]:
    bc = blob.get_blob_client(PRED_CONTAINER, f"{run_id}/predictions.jsonl")
    if not bc.exists():
        raise HTTPException(404, f"Run {run_id} not found")
    data = bc.download_blob().readall().decode("utf-8").splitlines()
    rows = [json.loads(x) for x in data if x.strip()]
    return rows

@app.get("/healthz")
def healthz():
    return {"ok": True}

@app.get("/runs")
def get_runs():
    return {"runs": list_runs()}

@app.get("/predictions")
def get_predictions(
    run_id: Optional[str] = None,
    view: Optional[Literal["confident","uncertain","human","avatar","other","none","all"]] = "all"
):
    runs = list_runs()
    if not runs:
        return {"runs": [], "items": []}
    run = run_id or runs[0]
    rows = read_predictions(run)
    def maxprob(r): 
        probs = [r["probs"].get(k,0.0) for k in ["human","avatar","other","none"]]
        return max(probs)
    def topcat(r):
        return max(r["probs"], key=r["probs"].get)

    if view == "confident":
        rows = [r for r in rows if maxprob(r) >= MIN_CONF]
    elif view == "uncertain":
        rows = [r for r in rows if maxprob(r) < LOW_CONF]
    elif view in {"human","avatar","other","none"}:
        rows = [r for r in rows if topcat(r) == view]
    # else: "all"

    return {"run_id": run, "count": len(rows), "items": rows}

@app.get("/image/{user_id}")
def get_image(user_id: str):
    # Serve from cache if present, else proxy Graph
    cache_client = blob.get_blob_client(CACHE_CONTAINER, f"{user_id}.jpg")
    if cache_client.exists():
        dat = cache_client.download_blob().readall()
        return StreamingResponse(io.BytesIO(dat), media_type="image/jpeg")
    # Graph
    url = f"https://graph.microsoft.com/v1.0/users/{user_id}/photo/$value"
    tok = graph_token()
    resp = requests.get(url, headers={"Authorization": f"Bearer {tok}"})
    if resp.status_code == 404:
        raise HTTPException(404, "No picture")
    if not resp.ok:
        raise HTTPException(resp.status_code, resp.text)
    return StreamingResponse(io.BytesIO(resp.content), media_type=resp.headers.get("Content-Type","image/jpeg"))

@app.post("/labels")
def post_label(item: dict):
    """
    Body: { "run_id": "...", "user_id": "...", "expected": "human|avatar|other|none", "notes": "..." }
    Stored as a row in Table 'labels' with (PartitionKey=run_id, RowKey=user_id).
    """
    required = {"run_id","user_id","expected"}
    if not required.issubset(item.keys()):
        raise HTTPException(400, f"Missing keys {required - set(item.keys())}")
    ent = {
        "PartitionKey": item["run_id"],
        "RowKey": item["user_id"],
        "expected": item["expected"],
        "notes": item.get("notes","")
    }
    tc = table.get_table_client(TABLE_LABELS)
    tc.upsert_entity(ent, mode="Merge")
    return {"ok": True}
