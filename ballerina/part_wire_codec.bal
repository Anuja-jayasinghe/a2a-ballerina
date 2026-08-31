// Copyright (c) 2026 WSO2 LLC (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

// Wire-level encode/decode helpers for Part.raw, split out of
// types.bal (which should hold type definitions, not functions).

import ballerina/lang.array;

# The set of field names that can hold, directly or transitively, a Part
# (or a structure containing one) somewhere in the v1.0 type hierarchy:
# Message.parts, Artifact.parts, Task.history (Message[]), Task.artifacts
# (Artifact[]), TaskStatus.message, TaskStatusUpdateEvent.status,
# TaskArtifactUpdateEvent.artifact, StreamResponse.task/.message/
# .statusUpdate/.artifactUpdate, SendMessageResult.task/.message, and
# ListTasksResult.tasks. `encodeRawBytesForWire`/`decodeRawBytesFromWire`
# only ever recurse into these exact key names — this is what keeps the
# walkers from touching free-form fields such as `metadata` (map<json> on
# Message/Task/Artifact/the two update events) or a data-Part's own
# `data` field, even when those free-form trees happen to contain a key
# literally named "raw" that has nothing to do with Part.raw.
final readonly & string[] partBearingContainerKeys = [
    "history", "artifacts", "message", "status", "task", "statusUpdate",
    "artifactUpdate", "artifact", "tasks"
];

isolated function isPartBearingContainerKey(string k) returns boolean {
    return partBearingContainerKeys.indexOf(k) is int;
}

# Rewrites the "raw" field of each Part-shaped element of a `parts` array
# (as produced by Message.parts/Artifact.parts) from the integer-array
# shape Ballerina's default byte[] serialization produces into a base64
# string. Only ever touches the "raw" key directly on a Part object; a
# Part's own `data`/`metadata` fields are left completely untouched, so a
# data-Part whose arbitrary JSON payload happens to contain a "raw" key is
# never mistaken for Part.raw.
#
# + partsValue - the json value of a `parts` field; expected to be a
#                json[] of Part-shaped objects, but tolerates other shapes
#                by returning them unchanged
# + return - the same array with every Part.raw integer-array rewritten to
#            a base64 string
isolated function encodePartsRawField(json partsValue) returns json {
    if partsValue !is json[] {
        return partsValue;
    }
    json[] result = [];
    foreach json part in partsValue {
        if part !is map<json> {
            result.push(part);
            continue;
        }
        map<json> partResult = {};
        foreach [string, json] [pk, pv] in part.entries() {
            if pk == "raw" && pv is json[] {
                byte[]|error asBytes = trap pv.cloneWithType();
                if asBytes is byte[] {
                    partResult[pk] = array:toBase64(asBytes);
                    continue;
                }
            }
            partResult[pk] = pv;
        }
        result.push(partResult);
    }
    return result;
}

# The reverse of encodePartsRawField: converts each Part-shaped element's
# "raw" field, when it is a base64 string, back into the integer-array
# shape cloneWithType expects for a byte[] field.
#
# + partsValue - the json value of a `parts` field
# + return - the same array with every Part.raw base64 string rewritten to
#            an integer-array, or an error if a "raw" string on an actual
#            Part isn't valid base64
isolated function decodePartsRawField(json partsValue) returns json|error {
    if partsValue !is json[] {
        return partsValue;
    }
    json[] result = [];
    foreach json part in partsValue {
        if part !is map<json> {
            result.push(part);
            continue;
        }
        map<json> partResult = {};
        foreach [string, json] [pk, pv] in part.entries() {
            if pk == "raw" && pv is string {
                byte[] decoded = check array:fromBase64(pv);
                partResult[pk] = decoded.toJson();
                continue;
            }
            partResult[pk] = pv;
        }
        result.push(partResult);
    }
    return result;
}

# Recursively walks a json value (already produced by a type's default
# .toJson()), converting any Part's raw field from the integer-array shape
# Ballerina's default byte[] serialization produces into a base64 string —
# the wire encoding every other A2A implementation expects for bytes
# fields (protobuf JSON mapping), and the only shape a real server can
# parse. Applied once, after toJson(), to any v1.0 Message/Task/Artifact/
# StreamResponse/etc. tree before it is sent — the v0.3 compat layer
# (compat_v03.bal's encodeV03Part) already handles this correctly on its
# own dialect-specific path and needs no change.
#
# Structure-aware, not key-name-driven: this only ever recurses into the
# fixed set of key names that can actually hold a Part somewhere beneath
# them (see `partBearingContainerKeys`), and within a `parts` array only
# ever touches the "raw" key of each Part-shaped element. Free-form
# fields — `metadata` on Message/Task/Artifact/the update events, and a
# data-Part's own `data` field — are never in that allow-list, so a
# caller's own JSON containing an unrelated key named "raw" (e.g.
# `metadata: {"raw": [1, 2, 3]}`) is passed through completely unchanged
# instead of being silently mistaken for Part.raw.
#
# + value - a json value (or subtree) to walk
# + return - the same tree with every Part.raw integer-array rewritten to
#            a base64 string
isolated function encodeRawBytesForWire(json value) returns json {
    if value is json[] {
        json[] result = [];
        foreach json v in value {
            result.push(encodeRawBytesForWire(v));
        }
        return result;
    }
    if value is map<json> {
        map<json> result = {};
        foreach [string, json] [k, v] in value.entries() {
            if k == "parts" {
                result[k] = encodePartsRawField(v);
            } else if isPartBearingContainerKey(k) {
                result[k] = encodeRawBytesForWire(v);
            } else {
                result[k] = v;
            }
        }
        return result;
    }
    return value;
}

# The reverse of encodeRawBytesForWire: converts any "raw" field that is a
# base64 string back into the integer-array shape cloneWithType expects
# for a byte[] field — Ballerina's cloneWithType cannot decode a base64
# string into byte[] itself (confirmed empirically: it requires an
# integer-array json shape), so this must run on every inbound v1.0
# Message/Task/Artifact/StreamResponse/etc. tree before cloneWithType is
# called, or a real server's base64-encoded response would fail to parse
# entirely.
#
# Structure-aware, not key-name-driven: same traversal allow-list as
# encodeRawBytesForWire (see `partBearingContainerKeys`), so a response
# whose free-form `metadata` happens to contain a "raw" key holding
# arbitrary non-base64 text no longer fails to decode — that key is
# simply never visited, because `metadata` is not in the allow-list.
#
# + value - a json value (or subtree) to walk
# + return - the same tree with every Part.raw base64 string rewritten to
#            an integer-array, or an error if a "raw" string on an actual
#            Part isn't valid base64
isolated function decodeRawBytesFromWire(json value) returns json|error {
    if value is json[] {
        json[] result = [];
        foreach json v in value {
            result.push(check decodeRawBytesFromWire(v));
        }
        return result;
    }
    if value is map<json> {
        map<json> result = {};
        foreach [string, json] [k, v] in value.entries() {
            if k == "parts" {
                result[k] = check decodePartsRawField(v);
            } else if isPartBearingContainerKey(k) {
                result[k] = check decodeRawBytesFromWire(v);
            } else {
                result[k] = v;
            }
        }
        return result;
    }
    return value;
}
