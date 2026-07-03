#!/bin/bash
#
# Create the TLS material used by this tutorial.
#
# Modelled on:
#   https://github.com/ibm-messaging/mq-helm/tree/main/samples/genericresources/createcerts
#
# Produces (under ./out):
#   ca.key       - the test root CA private key
#   ca.crt       - the test root CA certificate (loaded into MQ's trust store)
#   qmgr.key     - the queue manager's private key
#   qmgr.crt     - the queue manager's certificate, signed by the root CA
#   mq-client.key
#   mq-client.crt
#   mq-client.p12  - PKCS#12 keystore used by the MQ C-language client
#   mq-client.kdb  - CMS keystore (built from the .p12 if runmqakm exists)
#
# Run from this directory:
#   ./create-certs.sh

set -euo pipefail

OUT="$(cd "$(dirname "$0")" && pwd)/out"
mkdir -p "$OUT"
cd "$OUT"

# Password used by the CMS keystore. amqsputc/amqsbcg will need to be told
# this via the MQCERTLABL / MQSSLKEYR setup later on.
KEYSTORE_PASSWORD="${KEYSTORE_PASSWORD:-passw0rd}"

# ---------------------------------------------------------------------------
# 1. Root CA
# ---------------------------------------------------------------------------
if [ ! -f ca.crt ]; then
  openssl genrsa -out ca.key 4096
  openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -subj "/CN=mq-tutorial-ca" \
    -out ca.crt
fi

# ---------------------------------------------------------------------------
# 2. Queue manager certificate
# ---------------------------------------------------------------------------
openssl genrsa -out qmgr.key 2048
openssl req -new -key qmgr.key \
  -subj "/CN=qmgr" \
  -out qmgr.csr
openssl x509 -req -in qmgr.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -sha256 \
  -out qmgr.crt
rm -f qmgr.csr

# ---------------------------------------------------------------------------
# 3. Application client certificate (CN=mq-client - matches the SSLPEERMAP
#    rule in mq.mqsc which assigns this client the "app" user)
# ---------------------------------------------------------------------------
openssl genrsa -out mq-client.key 2048
openssl req -new -key mq-client.key \
  -subj "/CN=mq-client" \
  -out mq-client.csr
openssl x509 -req -in mq-client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -days 3650 -sha256 \
  -out mq-client.crt
rm -f mq-client.csr

# ---------------------------------------------------------------------------
# 4. Bundle the client's personal cert + key into a PKCS#12 keystore.
#    Do NOT include ca.crt via -certfile: runmqakm -cert -import applies
#    -new_label to every certificate in the archive, so a bundled CA would
#    collide with the personal cert on the same label and GSKit would fail
#    with "CTGSK2021W A duplicate certificate already exists in the database".
#    The CA is added to the CMS keystore separately (see step 5, and the
#    equivalent block in client/client-pod.yaml).
#    The "friendlyName" becomes the certificate label expected by the MQ
#    client when the application sets MQCERTLABL=mq-client.
# ---------------------------------------------------------------------------
openssl pkcs12 -export \
  -inkey  mq-client.key \
  -in     mq-client.crt \
  -name   mq-client \
  -out    mq-client.p12 \
  -passout pass:"$KEYSTORE_PASSWORD"

# ---------------------------------------------------------------------------
# 5. If the IBM MQ runmqakm tool is available (ships in the MQ container)
#    convert to the CMS .kdb format the MQ C-language samples expect.
#    Most users will instead run this conversion inside the client pod via
#    "kubectl exec" - see the README.
# ---------------------------------------------------------------------------
if command -v runmqakm >/dev/null 2>&1; then
  runmqakm -keydb -create -db mq-client.kdb \
    -pw "$KEYSTORE_PASSWORD" -type cms -stash
  # Personal cert: the p12's friendly name is already "mq-client" so no
  # -new_label is needed.
  runmqakm -cert -import -file mq-client.p12 \
    -pw "$KEYSTORE_PASSWORD" -type p12 \
    -target mq-client.kdb -target_pw "$KEYSTORE_PASSWORD" \
    -target_type cms
  # Signer cert: add the CA so the client can verify the qmgr's cert.
  runmqakm -cert -add -db mq-client.kdb -pw "$KEYSTORE_PASSWORD" \
    -type cms -file ca.crt -label mq-tutorial-ca -format ascii
fi

echo
echo "Generated under $OUT:"
ls -1 "$OUT"
