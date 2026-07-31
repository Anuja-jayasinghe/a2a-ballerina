// Tests for AgentCard JWS signature verification (RFC 7515).
//
// The RS256 test fixture below is built from a real, offline-generated RSA
// keypair (via the JDK's keytool, since ballerina/crypto has no
// key-generation function) and a real signature computed by actually
// running crypto:signRsaSha256 over this exact card's JSON (with
// `signatures` emptied to `[]`) using that keypair's private key — not a
// hand-crafted string. The tampered-card test is what actually proves
// verifyAgentCardSignature does real cryptographic work: if it were
// replaced with `return true;`, only that test would fail.
import ballerina/test;
import ballerina/crypto;

@test:Config {}
function testVerifyAgentCardSignatureRs256Valid() returns error? {
    AgentCard signedCard = buildRs256SignedTestCard();
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean result = check verifyAgentCardSignature(signedCard, publicKey);
    test:assertTrue(result, "signature over an unmodified card should verify");
}

@test:Config {}
function testVerifyAgentCardSignatureRs256TamperedCardFails() returns error? {
    AgentCard signedCard = buildRs256SignedTestCard();
    AgentCard tampered = signedCard.clone();
    tampered.description = "a different description than what was signed";
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean result = check verifyAgentCardSignature(tampered, publicKey);
    test:assertFalse(result, "signature should not verify once card content changes");
}

@test:Config {}
function testVerifyAgentCardSignatureUnsupportedAlgErrors() returns error? {
    AgentCard card = buildRs256SignedTestCard();
    // Rewrite the protected header's alg to something this library
    // deliberately doesn't support (e.g. EdDSA, since ballerina/crypto has
    // no verification function for it) and confirm a clear typed error,
    // not a crash or a false "true".
    card.signatures[0].protected = encodeProtectedHeaderWithAlg("EdDSA");
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean|error result = verifyAgentCardSignature(card, publicKey);
    test:assertTrue(result is UnsupportedSignatureAlgorithmError,
            "an alg this library can't verify should error with the typed UnsupportedSignatureAlgorithmError, not silently return false or true");
}

@test:Config {}
function testVerifyAgentCardSignatureOutOfRangeIndexErrors() returns error? {
    AgentCard card = buildRs256SignedTestCard();
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean|error result = verifyAgentCardSignature(card, publicKey, 1);
    test:assertTrue(result is SignatureVerificationError,
            "a signatureIndex past the end of card.signatures should error with the typed SignatureVerificationError");
}

@test:Config {}
function testVerifyAgentCardSignatureNegativeIndexErrors() returns error? {
    AgentCard card = buildRs256SignedTestCard();
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean|error result = verifyAgentCardSignature(card, publicKey, -1);
    test:assertTrue(result is SignatureVerificationError,
            "a negative signatureIndex should error with the typed SignatureVerificationError, not raise an uncaught index error");
}

@test:Config {}
function testVerifyAgentCardSignatureMalformedBase64ProtectedHeaderErrors() returns error? {
    // "!!!not-base64url!!!" contains characters outside the base64url
    // alphabet, so decoding the protected header must fail — and that
    // failure must surface as the typed SignatureVerificationError, not a
    // bare/raw error, per the function's "malformed JWS structure" promise.
    AgentCard card = buildRs256SignedTestCard();
    card.signatures[0].protected = "!!!not-base64url!!!";
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean|error result = verifyAgentCardSignature(card, publicKey);
    test:assertTrue(result is SignatureVerificationError,
            "a protected header that isn't valid base64url should error with the typed SignatureVerificationError, not a bare error");
}

@test:Config {}
function testVerifyAgentCardSignatureNonJsonProtectedHeaderErrors() returns error? {
    // Valid base64url, but the decoded bytes aren't valid JSON — must also
    // surface as the typed SignatureVerificationError.
    AgentCard card = buildRs256SignedTestCard();
    card.signatures[0].protected = encodeBase64Url("not { valid json".toBytes());
    crypto:PublicKey publicKey = check crypto:decodeRsaPublicKeyFromContent(testRs256CertBytes());
    boolean|error result = verifyAgentCardSignature(card, publicKey);
    test:assertTrue(result is SignatureVerificationError,
            "a protected header whose decoded bytes aren't valid JSON should error with the typed SignatureVerificationError, not a bare error");
}

// Fixed RSA test keypair generated once offline via the JDK's keytool
// (ballerina/crypto has no key-generation function):
//   keytool -genkeypair -alias a2atest -keyalg RSA -keysize 2048 \
//     -validity 3650 -keystore test.p12 -storetype PKCS12 \
//     -storepass changeit -keypass changeit -dname "CN=a2a-test"
//   keytool -exportcert -alias a2atest -keystore test.p12 \
//     -storepass changeit -rfc -file test_cert.pem
// Only the public certificate is needed at test time (for
// decodeRsaPublicKeyFromContent), so the private key/keystore itself is
// not checked in — only the certificate PEM and a signature that was
// actually computed with the corresponding private key using
// crypto:signRsaSha256 over buildRs256SignedTestCard()'s own JSON (with
// signatures cleared), run once, offline.
isolated function testRs256CertBytes() returns byte[] => string `-----BEGIN CERTIFICATE-----
MIICyTCCAbGgAwIBAgIIP2u98j1AmIQwDQYJKoZIhvcNAQEMBQAwEzERMA8GA1UE
AxMIYTJhLXRlc3QwHhcNMjYwNzMwMTU0MjUwWhcNMzYwNzI3MTU0MjUwWjATMREw
DwYDVQQDEwhhMmEtdGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
AIXxKK/9CEQegx9F+fOwostiIFXyB4+r9O1d6OOZiTcvzvJkeH3rw4kb0SgXOeoX
QLTynBk6Xq9PX9yBi2TpGZdbPgVR1v5Ff0U1Ig7m8Bbx7oL1adb/DK116Wsyx8ew
YZ8z5uONGuxvYlY4+eX8E1aPV9UsauWaHIjSmvp8BHpPSOhJW4UdXJsUCBhxQ8DX
Y/yyJih3tizMlhudTTv11fGURbu4MqrZ/XHjoKc0Ad3pgEQ8A/JR4x+mOW3Z3S7D
XFqY+oxdiwLpJsVeWjOl71zqbxxhz6krFJQoXCi+1eulUPa8lBjMj2/R1cQ1mt/+
7DmhyiI+lnlJS+Jxef1C5g8CAwEAAaMhMB8wHQYDVR0OBBYEFBpAo5AwSQKZ+sAu
tLdSNB9jZbYqMA0GCSqGSIb3DQEBDAUAA4IBAQBXT900iGACuMhJLTiXumhjEF9Q
DYPIy95MVdtGoAr6ZFv7ytIkPzEOkGTXTf2CkkIkSB2Beb/R6hd+gbCwgtpTQMkC
3QYRiRy/wMHTFBlWbJOr8ARq2dXOcbrn22VNAvIkpKGyZcxi39fm7+KQ+0g4GnZO
dakujcBQ1CKyBliWzqhsDCdt+y3uXZhoz/Hn5gB6iY73GJUd9eOuh/dzGMwFcVxq
Iu8icGAu/+MRRdUGDeYPttnnYEH+gmb4jJEhw7a0pUXe9JmWXJtOZ9+M1QwDvnQY
G1jwItdyykNQeN1U/aheH94i0dMx+94oKSurh5BGiwEPNLbxPpUMsUYFrSo0
-----END CERTIFICATE-----
`.toBytes();

isolated function buildRs256SignedTestCard() returns AgentCard {
    AgentCard card = {
        name: "Test Agent",
        description: "fixture",
        version: "1.0.0",
        capabilities: {},
        skills: [],
        signatures: [{
            protected: "eyJhbGciOiJSUzI1NiJ9",
            signature: "bf-cQUn26IQ8z9sDpWQhsiqfSKORC60At1FSzG1pOCF_bqc1YUEx8Ynr5X64bWzSiaLRK7r4LVd9RcG1TdynkxsZKVqor-qJpYECkf3VuQcyJqBQJx6OFriuRR6St1bo4gRURFnLZ524B-bz6jhHD_UC3Q8r4N2sT3yo1bPEaJCszuwtc7UaZU1kB8Jax4lQl2NCr_5C-paY7MW-J0KUFNTQxidnIOKDBymSG8RIVi6PeDUhYpskMRYFYMllRQvVBR3PsmEesehHBXQRbk59bB4Gv5ipeJMxpQxoZeA4jh5qrhhC5YLOYs6pJNdShzlfa2GG9NoIAdRQzfj3m703RQ"
        }]
    };
    return card;
}

isolated function encodeProtectedHeaderWithAlg(string alg) returns string {
    json header = {"alg": alg};
    return encodeBase64Url(header.toJsonString().toBytes());
}
