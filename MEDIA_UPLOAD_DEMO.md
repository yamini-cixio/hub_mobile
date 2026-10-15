# Camera & Voice Media Upload — Demo Document

> Demo guide for the **Media** feature: capturing voice / photo / video on the
> phone and uploading it to Amazon S3 through a presign **AWS Lambda** Function
> URL. This document describes the workflow, the exact Lambda request/response
> contract, and a step-by-step demo script.

---

## 1. Purpose (the "why")

- **Capture-first, offline-resilient.** Every voice note, photo and video is
  written to the phone's local storage **before** any network call, then queued.
- **No AWS credentials in the app.** The app asks a Lambda Function URL for a
  short-lived **presigned URL**, then uploads the bytes straight to S3.
- **Self-healing uploads.** Files that fail to upload are retried automatically
  (in-app timer every 2 minutes, on app-resume, and via OS background tasks).
- **Large-file ready.** Small files use a single presigned `PUT`; files larger
  than **100 MiB** use **S3 multipart upload** in chunks.

---

## 2. High-level architecture

```
┌─────────────────────────── Phone (Flutter app) ───────────────────────────┐
│                                                                           │
│  Media tab                                                                │
│   ├─ Voice  ─────► record mic (record plugin)                             │
│   ├─ Photo  ─────► native camera (image_picker)                           │
│   └─ Video  ─────► native camera (image_picker)                           │
│                          │                                                │
│                          ▼                                                │
│             Save file locally + enqueue (MediaStore / media_queue.json)   │
│                          │                                                │
│                          ▼                                                │
│             MediaUploader.syncPending()                                   │
│                          │                                                │
│        ┌─────────────────┴─────────────────┐                              │
│        │ 1. POST presign request            │  (no AWS creds)             │
│        ▼                                    ▼                              │
│   Lambda Function URL ──► returns presigned URL(s)                        │
│        │                                                                  │
│        │ 2. PUT file bytes directly to S3                                 │
│        ▼                                                                  │
└────────┼──────────────────────────────────────────────────────────────────┘
         ▼
   Amazon S3 bucket: cixio-hub (ap-south-1)
   Key prefix: testing/user1/
```

**Key components**

| Layer | File | Responsibility |
|---|---|---|
| UI | `lib/screens/media/media_screen.dart` | Voice/Photo/Video buttons, live status list |
| Service | `lib/services/media_service.dart` | Capture, local save, enqueue, retry timer |
| Queue | `lib/services/media_store.dart` | Durable JSON queue + `media/` folder |
| Uploader | `lib/services/media_uploader.dart` | Orchestrates upload of pending items |
| S3 client | `lib/services/presign_upload_service.dart` | Talks to Lambda + S3 (single & multipart) |
| Background | `lib/services/background_sync.dart` | WorkManager / BGTaskScheduler retries |
| Config | `lib/config/app_config.dart` | Reads `AWS_UPLOAD_URL` from `.env`/`--dart-define` |

---

## 3. Configuration

The Lambda endpoint is supplied through the bundled `.env` file (or
`--dart-define=AWS_UPLOAD_URL=...`):

```
AWS_UPLOAD_URL=https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/
```

- **Endpoint:** `https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/`
- **Bucket:** `cixio-hub`
- **Region:** `ap-south-1` (Mumbai)
- **Key prefix:** `testing/user1/`
- **Method:** `POST`, `Content-Type: application/json`

An unknown `action` value makes the Lambda reply
`{"error":"Invalid action type specified"}`.

---

## 4. The Lambda contract (what the app sends & receives)

The app talks to the Lambda in up to **three** calls. Small files need only
call #1 + a direct S3 PUT. Large files use all three.

### 4.1 Single upload — get one presigned URL

**App sends**

```http
POST https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/
Content-Type: application/json

{
  "fileName": "demo.jpg",
  "mimeType": "image/jpeg"
}
```

**Lambda responds**

```json
{
  "mode": "SINGLE",
  "presignedUrl": "https://cixio-hub.s3.ap-south-1.amazonaws.com/testing/user1/1792041204870-demo.jpg?X-Amz-Algorithm=...&X-Amz-Signature=...",
  "objectKey": "testing/user1/1792041204870-demo.jpg",
  "mimeType": "image/jpeg"
}
```

**Then the app** does a direct HTTP `PUT` of the file bytes to `presignedUrl`
(no AWS credentials involved). The S3 object key is `objectKey`.

> Note: the Lambda generates a unique key by prefixing a timestamp
> (`<epoch-ms>-<fileName>`).

---

### 4.2 Multipart — step 1: initiate

Used when the file is larger than `multipartThreshold` (default **100 MiB**).

**App sends**

```http
POST https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/
Content-Type: application/json

{
  "action": "MULTIPART_INITIATE",
  "fileName": "demo.mp4",
  "mimeType": "video/mp4",
  "size": 15728640,
  "totalParts": 2
}
```

- `size` — total file size in bytes.
- `totalParts` — how many chunks the app wants (the Lambda returns one presigned
  URL per part).

**Lambda responds**

```json
{
  "mode": "MULTIPART",
  "uploadId": "wl.33qGOFM7iF8GBBshBEVk972QAxcm2.9WbA4FE...",
  "objectKey": "testing/user1/1792041209378-demo.mp4",
  "parts": [
    {
      "partNumber": 1,
      "url": "https://cixio-hub.s3.ap-south-1.amazonaws.com/testing/user1/1792041209378-demo.mp4?X-Amz-Algorithm=...&partNumber=1&uploadId=wl.33qG...&x-id=UploadPart"
    },
    {
      "partNumber": 2,
      "url": "https://cixio-hub.s3.ap-south-1.amazonaws.com/testing/user1/1792041209378-demo.mp4?X-Amz-Algorithm=...&partNumber=2&uploadId=wl.33qG...&x-id=UploadPart"
    }
  ]
}
```

### 4.3 Multipart — step 2: upload each part

**App** `PUT`s each chunk to its matching `url`:

```http
PUT <url for partNumber 1>   (bytes 0 .. 10 MiB-1)
PUT <url for partNumber 2>   (remaining bytes)
```

**S3 responds** `200 OK` with an `ETag` response header per part:

```
ETag: "8acbe32feb9842ecc84b84d967ebb7f8"
```

The app collects `{partNumber, ETag}` for every part.

### 4.4 Multipart — step 3: complete

**App sends** (note the **capitalised** `PartNumber` / `ETag` — required)

```http
POST https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/
Content-Type: application/json

{
  "action": "MULTIPART_COMPLETE",
  "uploadId": "wl.33qGOFM7iF8GBBshBEVk972QAxcm2.9WbA4FE...",
  "objectKey": "testing/user1/1792041209378-demo.mp4",
  "parts": [
    { "PartNumber": 1, "ETag": "\"8acbe32feb9842ecc84b84d967ebb7f8\"" },
    { "PartNumber": 2, "ETag": "\"41cb1d65978992627f27c958347c10c9\"" }
  ]
}
```

**Lambda responds**

```json
{
  "message": "Multipart upload completed",
  "location": "https://cixio-hub.s3.ap-south-1.amazonaws.com/testing%2Fuser1%2F1792041209378-demo.mp4"
}
```

### 4.5 Error responses

| Situation | Response |
|---|---|
| Unknown `action` | `{"error":"Invalid action type specified"}` |
| Bad/unauthorised request to S3 during complete | `{"error":"The specified method is not allowed against this resource."}` or an S3 XML `<Error><Code>…</Code><Message>…</Message></Error>` |
| HTTP non-2xx | App throws `PresignUploadException` with the extracted message + status code |

> There is **no abort action** on this Lambda. If a multipart upload fails midway
> the app retries from scratch; orphaned parts are cleaned up by an S3 lifecycle
> rule (recommended).

---

## 5. What the app stores / shows

Each captured file becomes a `MediaItem` with:

| Field | Meaning |
|---|---|
| `id` | UUID |
| `type` | `voice` / `photo` / `video` |
| `localPath` | path in app storage |
| `fileName` | UUID-based name (e.g. `a1b2….mp4`) |
| `mimeType` | `audio/mp4`, `image/jpeg`, `video/mp4` |
| `sizeBytes` | file size |
| `status` | `pending` → `uploading` → `uploaded` / `failed` |
| `attempts` | number of tries |
| `s3Key` | set after a successful upload |

The Media list shows a coloured status chip per item:
**Uploading** (blue, spinner), **Uploaded** (green), **Pending** (orange),
**Failed/Retry N** (red — long-press for the error).

Retry cadence: in-app timer every **2 minutes**, on **app resume**, and via OS
background tasks (Android WorkManager; iOS BGTaskScheduler on physical devices).

---

## 6. Demo script (~2 minutes)

1. **Open the app → Media tab** (3rd in the bottom nav).
   Point at the top banner: *"All files uploaded"* with a green cloud.
2. **Voice** — tap the red **Voice** button → the "Voice note" sheet opens and
   starts recording with a live timer → speak 3–5 s → tap **Stop & save**.
   - Snackbar: *"Voice note saved locally — uploading…"*
   - The new row flips **Pending → Uploading → Uploaded**; the cloud stays green.
3. **Photo** — tap **Photo** → take a shot → watch the same lifecycle.
4. **Video** — tap **Video** → record ~5 s → watch it upload.
5. **Resilience** — pull down to refresh (or tap **Sync now**) to demonstrate the
   retry mechanism.
6. **Delete** — tap the trash icon → dialog notes the local copy is removed while
   an already-uploaded S3 object is kept.

### Optional: show the Lambda live

With a terminal visible, run the exact calls the app makes:

```bash
# Single
curl -s -X POST "https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/" \
  -H "Content-Type: application/json" \
  -d '{"fileName":"demo.jpg","mimeType":"image/jpeg"}'

# Multipart initiate
curl -s -X POST "https://3yzckdgen2ogld553howb2sj3y0yoisu.lambda-url.ap-south-1.on.aws/" \
  -H "Content-Type: application/json" \
  -d '{"action":"MULTIPART_INITIATE","fileName":"demo.mp4","mimeType":"video/mp4","size":15728640,"totalParts":2}'
```

---

## 7. Talking points

- "The file is written to the phone **first**; uploads never block capture."
- "**No AWS keys** ship in the app — the Lambda issues short-lived presigned URLs."
- "Uploads are **self-healing**: retried every 2 minutes and whenever the app reopens."
- "Large videos use **S3 multipart upload**, so a dropped connection only costs one part, not the whole file."

---

## 8. Caveats / troubleshooting

- **Multipart only triggers above 100 MiB** (`multipartThreshold` in
  `presign_upload_service.dart`). To demonstrate multipart, record a long HD
  video or temporarily lower the threshold (e.g. `5 * 1024 * 1024` when the
  service is built in `media_uploader.dart`).
- **Use a physical device** for the full background story. The iOS Simulator
  skips BGTaskScheduler; foreground upload + timer still work there.
- **Network:** the device must reach the Lambda URL and
  `cixio-hub.s3.ap-south-1.amazonaws.com`.
- **Rebuild after code changes:** the S3 client is pure Dart, so a fresh
  `flutter run` reflects any change (hot restart is enough).
