// AgentCard JWS signature verification (RFC 7515). This library has
// always captured AgentCardSignature's shape (types.bal) without
// verifying it — a forged or tampered card would go undetected. This
// closes that gap for a caller who already holds the expected public key
// (pinned, or fetched out-of-band); automatic key discovery via a JWK set
// URL is a separate, larger feature and not in scope here.
//
// Scoped to RS256 and ES256 — the two algorithms ballerina/crypto actually
// has verification functions for. A card signed with any other alg (e.g.
// EdDSA, which ballerina/crypto cannot verify at all) is rejected with a
// clear error rather than silently skipped or falsely accepted.

import ballerina/crypto;
import ballerina/lang.array;

# Decodes a base64url string (RFC 4648 §5 — the alphabet JWS uses
# throughout: '-'/'_' instead of '+'/'/', no padding), which
# ballerina/crypto and ballerina/lang.array only provide standard-alphabet
# base64 decoding for.
#
# + encoded - the base64url-encoded string
# + return - the decoded bytes, or an error if not valid base64url
isolated function decodeBase64Url(string encoded) returns byte[]|error {
    string standard = re `-`.replaceAll(re `_`.replaceAll(encoded, "/"), "+");
    int padNeeded = (4 - standard.length() % 4) % 4;
    string pad = "";
    foreach int i in 0 ..< padNeeded {
        pad += "=";
    }
    return array:fromBase64(standard + pad);
}

# Encodes bytes as base64url (RFC 4648 §5, no padding) — the alphabet JWS
# uses throughout. `array:toBase64` only produces standard-alphabet,
# padded base64, which is a different string (and thus a different JWS
# signing input) whenever the encoded bytes would contain '+', '/', or
# trailing '=' padding — using it directly for the payload half of the
# signing input would silently diverge from RFC 7515 and fail to verify
# genuine JWS signatures produced by a real, spec-compliant signer.
#
# + data - the bytes to encode
# + return - the base64url-encoded string, without padding
isolated function encodeBase64Url(byte[] data) returns string {
    string standard = array:toBase64(data);
    string noPad = re `=+$`.replace(standard, "");
    return re `/`.replaceAll(re `\+`.replaceAll(noPad, "-"), "_");
}

# Verifies one of an AgentCard's JWS signatures (RFC 7515) against a
# caller-supplied public key. The JWS payload is the AgentCard's own JSON
# serialization with the `signatures` field itself emptied to `[]` (it's
# non-optional, so it's still present in the serialized JSON as an empty
# array, not actually removed — a signature can't cover itself)
# — reconstructed here rather than trusting any
# embedded payload, since JWS's compact form for a detached signature
# carries no payload of its own.
#
# LIMITATION: does not perform RFC 8785 JSON Canonicalization (JCS). Spec
# §8.4.1 ("Canonicalization Requirements") requires Agent Card signing to
# canonicalize the card's JSON via JCS before computing the JWS signing
# input, precisely so that different JSON serializers' field ordering and
# number/string formatting don't produce different signing bytes for
# semantically identical cards. This function instead reconstructs the
# signing payload via Ballerina's own toJsonString (record-declaration
# field order, Ballerina's own formatting) — it will only verify
# signatures computed over that exact serialization, not signatures
# produced by a real, spec-conformant JCS signer (e.g. a Python or Java
# reference implementation). This is fail-closed (a genuinely
# validly-signed, spec-conformant card may verify as `false`; a
# forged/tampered card is never falsely accepted), but it means
# verification against non-Ballerina-signed cards is not yet reliable.
# JCS was deliberately not implemented here: doing it correctly (recursive
# Unicode-code-point key sorting, ECMAScript-compatible number formatting,
# ECMA-262 string escaping) is intricate enough, especially given
# `AgentCard`'s open `json...` fields can carry arbitrary data including
# numbers, that a partial/incorrect implementation risked silently wrong
# results — worse than this documented gap.
#
# + card - the AgentCard to verify, including its `signatures` entries
# + publicKey - the key to verify against
# + signatureIndex - which entry of card.signatures to verify, if more
#                     than one is present; defaults to the first
# + return - true if the signature is valid for this exact card content,
#            false if it doesn't match (not an error — a tampered or
#            wrongly-keyed card is an expected, checkable outcome), or a
#            `SignatureVerificationError` if signatureIndex is out of
#            range or the JWS structure is malformed (bad base64url, bad
#            JSON, missing/non-string `alg`), or an
#            `UnsupportedSignatureAlgorithmError` if the protected
#            header's alg is anything other than RS256/ES256 (the only
#            algorithms ballerina/crypto can verify)
public isolated function verifyAgentCardSignature(
        AgentCard card,
        crypto:PublicKey publicKey,
        int signatureIndex = 0) returns boolean|SignatureVerificationError|UnsupportedSignatureAlgorithmError {
    if signatureIndex < 0 || signatureIndex >= card.signatures.length() {
        return error SignatureVerificationError(string `signatureIndex ${signatureIndex} out of range: card has ${card.signatures.length()} signature(s)`);
    }
    AgentCardSignature sig = card.signatures[signatureIndex];

    byte[]|error headerBytesResult = decodeBase64Url(sig.protected);
    if headerBytesResult is error {
        return error SignatureVerificationError(
                string `protected header is not valid base64url: ${headerBytesResult.message()}`, headerBytesResult);
    }
    byte[] headerBytes = headerBytesResult;

    string|error headerStrResult = string:fromBytes(headerBytes);
    if headerStrResult is error {
        return error SignatureVerificationError(
                string `protected header bytes are not valid UTF-8: ${headerStrResult.message()}`, headerStrResult);
    }
    string headerStr = headerStrResult;

    json|error headerResult = headerStr.fromJsonString();
    if headerResult is error {
        return error SignatureVerificationError(
                string `protected header is not valid JSON: ${headerResult.message()}`, headerResult);
    }
    json header = headerResult;

    json|error algJsonResult = header.alg;
    if algJsonResult is error {
        return error SignatureVerificationError(
                string `protected header has no "alg" field: ${algJsonResult.message()}`, algJsonResult);
    }
    string|error algResult = algJsonResult.ensureType();
    if algResult is error {
        return error SignatureVerificationError(
                string `protected header's "alg" is not a string: ${algResult.message()}`, algResult);
    }
    string alg = algResult;

    AgentCard unsigned = card.clone();
    unsigned.signatures = [];
    byte[] payload = unsigned.toJsonString().toBytes();

    // JWS compact-form signing input is base64url(protected header) + "." +
    // base64url(payload) — reconstructed here since AgentCardSignature only
    // stores the protected header and the signature, not the payload
    // (detached-payload JWS, per the spec's own AgentCardSignature shape).
    // Both halves must use base64url (RFC 7515), not standard base64 —
    // array:toBase64 alone would diverge from a real signer's bytes
    // whenever the payload's encoding needs '+', '/', or '=' padding.
    string signingInput = sig.protected + "." + encodeBase64Url(payload);
    byte[]|error signatureBytesResult = decodeBase64Url(sig.signature);
    if signatureBytesResult is error {
        return error SignatureVerificationError(
                string `signature value is not valid base64url: ${signatureBytesResult.message()}`, signatureBytesResult);
    }
    byte[] signatureBytes = signatureBytesResult;

    if alg == "RS256" {
        boolean|crypto:Error result = crypto:verifyRsaSha256Signature(signingInput.toBytes(), signatureBytes, publicKey);
        if result is crypto:Error {
            return error SignatureVerificationError(
                string `RS256 signature verification failed: ${result.message()}`, result);
        }
        return result;
    } else if alg == "ES256" {
        boolean|crypto:Error result = crypto:verifySha256withEcdsaSignature(signingInput.toBytes(), signatureBytes, publicKey);
        if result is crypto:Error {
            return error SignatureVerificationError(
                string `ES256 signature verification failed: ${result.message()}`, result);
        }
        return result;
    }
    return error UnsupportedSignatureAlgorithmError(
        string `unsupported JWS alg "${alg}" — this library can only verify RS256 and ES256`);
}
