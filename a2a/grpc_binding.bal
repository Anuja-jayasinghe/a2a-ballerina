// Conversion layer between the generated grpcstub:* protobuf types and
// this library's own types.bal domain types. Mirrors compat_v03.bal's
// encodeV03*/parseV03* pattern for the same reason: the generated records
// are structurally incompatible with types.bal (snake_case fields, closed
// records, sentinel-default presence, map fields as key/value arrays,
// google.protobuf.Timestamp as a time:Utc tuple) — see the design spec's
// Finding 4 for the full enumeration. No amount of cloneWithType bridges
// that.
import ballerina/a2a.grpcstub;
import ballerina/time;

# Converts a generated proto map field (a key/value record array, since
# protobuf maps generate that shape rather than a real Ballerina map — see
# design spec Finding 4d) into a real map<string>.
#
# + kv - the generated key/value array
# + return - an equivalent map<string>
isolated function grpcKvToMap(record {|string key; string value;|}[] kv) returns map<string> {
    map<string> result = {};
    foreach var entry in kv {
        result[entry.key] = entry.value;
    }
    return result;
}

# The reverse of grpcKvToMap: builds the key/value array shape a generated
# proto map field expects from a real map<string>.
#
# + m - the map to convert
# + return - the equivalent key/value array
isolated function mapToGrpcKv(map<string> m) returns record {|string key; string value;|}[] {
    record {|string key; string value;|}[] result = [];
    foreach [string, string] [k, v] in m.entries() {
        result.push({key: k, value: v});
    }
    return result;
}

# Converts a generated google.protobuf.Timestamp (time:Utc tuple) into an
# RFC 3339 string, per types.bal's string? timestamp field convention.
# The proto3 sentinel default [0, 0.0d] (Unix epoch) decodes to () rather
# than to "1970-01-01T00:00:00Z" — per design spec Design decision 5, rule
# 3, this is the highest-risk silent-corruption case in the whole layer: a
# TaskStatus.timestamp of [0, 0.0d] means "field not set", not "set to the
# epoch."
#
# + ts - the generated timestamp value
# + return - the RFC 3339 string, or () if ts is the proto3 zero-default
isolated function grpcTimestampToString(time:Utc ts) returns string? {
    if ts[0] == 0 && ts[1] == 0.0d {
        return ();
    }
    // time:utcToString already renders the fractional-second component
    // (ts[1], a decimal in [0, 1)) correctly when non-zero, e.g.
    // "2023-10-27T10:00:00.500Z". No manual millisecond suffix is needed
    // -- appending one here would double up the fractional part and
    // produce a string that stringToGrpcTimestamp can't parse back.
    return time:utcToString(ts);
}

# The reverse of grpcTimestampToString: () encodes to the proto3
# zero-default [0, 0.0d], matching what an unset non-optional Timestamp
# field looks like on the wire.
#
# + s - the RFC 3339 string, or ()
# + return - the equivalent time:Utc tuple, or an error if s is a non-()
#            value that isn't valid RFC 3339
isolated function stringToGrpcTimestamp(string? s) returns time:Utc|error {
    if s is () {
        return [0, 0.0d];
    }
    return check time:utcFromString(s);
}

# Non-optional proto3 string fields default to "" when unset; types.bal
# models the same fields as string?. Per design spec Design decision 5,
# rule 1, "" always decodes to () for these fields — there is no way on
# the wire to distinguish "explicitly set to empty string" from "unset",
# so () is the only correct decoding.
#
# + s - the generated string field's value
# + return - s unchanged, or () if s is empty
isolated function emptyGrpcStringToNil(string s) returns string? {
    return s.length() == 0 ? () : s;
}

# Converts a generated google.protobuf.Struct field (map<anydata>, per
# design spec Finding 4d) into map<json>?, matching types.bal's metadata/
# params/header field convention. An empty struct decodes to () rather
# than {} — per Design decision 5 rule 2, an all-defaults nested message
# means "not set," and an empty Struct is exactly that case for this
# field type.
#
# + struct - the generated Struct field's value
# + return - the equivalent map<json>, or () if struct is empty, or an
#            error if a value inside it falls outside json's value space
isolated function grpcStructToJson(map<anydata> struct) returns map<json>?|error {
    if struct.length() == 0 {
        return ();
    }
    json|error asJson = struct.cloneWithType(json);
    if asJson is error {
        return error InvalidAgentResponseError(
            string `struct field could not be narrowed to json: ${asJson.message()}`,
            message = string `struct field could not be narrowed to json: ${asJson.message()}`
        );
    }
    map<json>|error result = asJson.ensureType();
    if result is error {
        return error InvalidAgentResponseError(
            string `struct field could not be narrowed to json: ${result.message()}`,
            message = string `struct field could not be narrowed to json: ${result.message()}`
        );
    }
    return result;
}

# The reverse of grpcStructToJson: () or an empty map both encode to an
# empty map<anydata> (the proto3 wire representation of "no Struct set").
#
# + j - the map<json>? field's value
# + return - the equivalent map<anydata>
isolated function jsonToGrpcStruct(map<json>? j) returns map<anydata> {
    if j is () {
        return {};
    }
    return j;
}

# Converts a typed Part into the generated grpcstub:Part shape.
#
# Callers must pass an already-typed Part (raw as byte[]?, not a base64
# string) — this function does not undo base64 encoding. That undoing, if
# needed, happens one layer up in encodeGrpcRequest (see its doc comment),
# not here, because this function's contract is "typed Part in, typed
# grpcstub:Part out," and base64 is a JSON-RPC/REST wire concern that
# never should have reached a typed Part value in the first place.
#
# + p - the Part to encode
# + return - the equivalent grpcstub:Part, or an error if p.data cannot be
#            widened (it always can: json is a strict subtype of anydata)
isolated function encodeGrpcPart(Part p) returns grpcstub:Part|error {
    grpcstub:Part result = {
        metadata: jsonToGrpcStruct(p?.metadata)
    };
    string? text = p?.text;
    byte[]? raw = p?.raw;
    string? url = p?.url;
    json? data = p?.data;
    if text is string {
        result.text = text;
    } else if raw is byte[] {
        result.raw = raw;
    } else if url is string {
        result.url = url;
    } else if data !is () {
        // json is a strict subtype of anydata, so this widening is total
        // and lossless (design spec Design decision 5, rule 5).
        result.data = data;
    }
    string? filename = p?.filename;
    if filename is string {
        result.filename = filename;
    }
    string? mediaType = p?.mediaType;
    if mediaType is string {
        result.media_type = mediaType;
    }
    return result;
}

# Converts a generated grpcstub:Part into a typed Part.
#
# + p - the generated Part to decode
# + partIndex - this part's index within its containing parts array, used
#               only to name the offending part in a narrowing-failure
#               error message
# + return - the equivalent typed Part, or InvalidAgentResponseError if
#            p.data (typed anydata on the wire, per the
#            google_protobuf_Value -> anydata workaround) holds a runtime
#            value json cannot represent — see design spec Design decision
#            5, rule 5, for why this is a real possible failure and not a
#            defensive check against something that can't happen
isolated function decodeGrpcPart(grpcstub:Part p, int partIndex) returns Part|error {
    Part result = {};
    string? text = p?.text;
    byte[]? raw = p?.raw;
    string? url = p?.url;
    anydata? data = p?.data;
    if text is string {
        result.text = text;
    } else if raw is byte[] {
        result.raw = raw;
    } else if url is string {
        result.url = url;
    } else if data !is () {
        json|error narrowed = trap data.cloneWithType(json);
        if narrowed is error {
            return error InvalidAgentResponseError(
                string `Part[${partIndex}].data holds a value that cannot be represented as json: ${narrowed.message()}`,
                message = string `Part[${partIndex}].data holds a value that cannot be represented as json: ${narrowed.message()}`,
                code = -32006
            );
        }
        result.data = narrowed;
    }
    string? filename = emptyGrpcStringToNil(p.filename);
    if filename is string {
        result.filename = filename;
    }
    string? mediaType = emptyGrpcStringToNil(p.media_type);
    if mediaType is string {
        result.mediaType = mediaType;
    }
    map<json>? metadata = check grpcStructToJson(p.metadata);
    if metadata is map<json> {
        result.metadata = metadata;
    }
    return result;
}
