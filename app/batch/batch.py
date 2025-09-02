import os, io, json, time, datetime, base64
import numpy as np
from PIL import Image
import requests
from azure.identity import ManagedIdentityCredential, DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

# ENV
STORAGE_ACCOUNT = os.getenv("STORAGE_ACCOUNT")
PRED_CONTAINER  = os.getenv("PRED_CONTAINER", "predictions")
CACHE_CONTAINER = os.getenv("CACHE_CONTAINER", "profilepics-cache")
MODEL_PATH      = os.getenv("MODEL_PATH", "/app/model/model.keras")
BATCH_LIMIT     = int(os.getenv("BATCH_LIMIT", "0"))  # 0 = all users

# Auth + clients
cred = DefaultAzureCredential(exclude_interactive_browser_credential=True)
msi  = ManagedIdentityCredential()
blob = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT}.blob.core.windows.net",
    credential=cred
)

# Load model
from tensorflow.keras.models import load_model
model = load_model(MODEL_PATH)
CLASS_ORDER = ["human","avatar","other"]  # "none" is reserved for missing pic

def graph_token() -> str:
    return msi.get_token("https://graph.microsoft.com/.default").token

def list_users():
    url = "https://graph.microsoft.com/v1.0/users?$select=id,displayName,userPrincipalName"
    tok = graph_token()
    items = []
    while url:
        r = requests.get(url, headers={"Authorization": f"Bearer {tok}"})
        r.raise_for_status()
        data = r.json()
        items.extend(data.get("value", []))
        url = data.get("@odata.nextLink")
    return items

def fetch_photo(user_id: str) -> bytes | None:
    url = f"https://graph.microsoft.com/v1.0/users/{user_id}/photo/$value"
    tok = graph_token()
    r = requests.get(url, headers={"Authorization": f"Bearer {tok}"})
    if r.status_code == 404:
        return None
    r.raise_for_status()
    return r.content

def preprocess(img_bytes: bytes) -> np.ndarray:
    img = Image.open(io.BytesIO(img_bytes)).convert("RGB")
    img = img.resize((224, 224))
    arr = np.array(img).astype("float32") / 255.0
    arr = np.expand_dims(arr, axis=0)  # (1,224,224,3)
    return arr

def softmax(x):
    e = np.exp(x - np.max(x))
    return e / e.sum(axis=-1, keepdims=True)

def run():
    users = list_users()
    if BATCH_LIMIT > 0:
        users = users[:BATCH_LIMIT]

    ts = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
    run_id = os.getenv("RUN_ID", ts)
    out_lines = []

    pred_cont = blob.get_container_client(PRED_CONTAINER)
    cache_cont = blob.get_container_client(CACHE_CONTAINER)

    for u in users:
        uid = u["id"]
        pic = fetch_photo(uid)
        if pic is None:
            probs = {"human": 0.0, "avatar": 0.0, "other": 0.0, "none": 1.0}
        else:
            # cache photo (best effort)
            try:
                cache_cont.upload_blob(f"{uid}.jpg", pic, overwrite=True)
            except Exception:
                pass
            x = preprocess(pic)
            logits = model.predict(x, verbose=0)[0]
            p = softmax(logits)
            probs = {CLASS_ORDER[i]: float(p[i]) for i in range(len(CLASS_ORDER))}
            probs["none"] = 0.0

        row = {
            "run_id": run_id,
            "user_id": uid,
            "displayName": u.get("displayName"),
            "upn": u.get("userPrincipalName"),
            "probs": probs
        }
        out_lines.append(json.dumps(row))

    # write predictions.jsonl
    blob_name = f"{run_id}/predictions.jsonl"
    pred_cont.upload_blob(blob_name, "\n".join(out_lines).encode("utf-8"), overwrite=True)
    print(f"Wrote blob: {PRED_CONTAINER}/{blob_name} ({len(out_lines)} rows)")

if __name__ == "__main__":
    run()
