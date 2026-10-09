# Plainpost Producer Notification Envelope v2

`PPN2` is the clean-break binary, ciphertext-only producer-to-iOS notification
envelope. There is no JSON production wire and no `PPN1` compatibility path.
All multibyte integers are unsigned big-endian.

The unsigned header binds the recipient routing handle and device, producer
device, opaque logical mailbox ID, producer assignment generation, current
trust epoch/revision/head, policy version, message digest, replay ID,
timestamps, collapse digest, ephemeral P-256 point, HKDF salt, and GCM nonce.
The header through nonce is AES-GCM AAD. The producer assignment generation
is mandatory and must match Central's current assignment before preparation
and on every durable retry.

The `PPR2` recipient record is exactly 285 bytes. Its fixed offsets are
`magic[0:4]`, account UUID `[4:20]`, recipient device UUID `[20:36]`, opaque
logical mailbox `[36:68]`, assignment generation u64 `[68:76]`, trust epoch
u64 `[76:84]`, trust revision u64 `[84:92]`, trust head `[92:124]`, routing
handle `[124:156]`, agreement P-256 X9.63 public key `[156:221]`, and raw
low-S P-256 signature `[221:285]`. The signature transcript is the
length-prefixed sequence `Plainpost.NotificationRecipientRegistration.v1`,
account, device, mailbox, generation u64, epoch u64, revision u64, trust head,
routing handle, and agreement public key, in that order.

The content key is HKDF-SHA256(ECDH-P256, random salt,
SHA-256(`Plainpost.ProducerNotification.v2.content-key` || AAD)). The raw
64-byte low-S P-256 signature is over SHA-256(
`Plainpost.ProducerNotification.v2.signature` || unsigned envelope).

The encrypted plaintext is version `2`, exactly six length-prefixed UTF-8
fields (opaque mailbox token, opaque thread token, opaque message token,
normalized sender, subject, preview), uint16 badge, replay ID, and issued and
expiry Unix seconds. All three opaque identity tokens are required and must
match the signed content identity. Bounds are 256/160/200/240 bytes, badge <=
999, plaintext <= 1024 bytes, ciphertext <= 2048 bytes, and complete envelope
<= 4096 bytes. All fields are UTF-8 and reject NUL. `PPN1` is rejected.
HTML, attachments, headers, labels, provider IDs, routes, credentials, and
full bodies are invalid inputs.

The relay verifies only the signed header and expiry. It sends the fixed APNs
fallback `New mail is available.` with mutable-content, exact envelope bytes,
opaque collapse digest, and expiry; live APNs token/topic/environment are not
persisted in the relay queue.
