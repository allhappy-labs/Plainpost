// Generated from Protocol/node-calendar-v1/node-calendar.schema.json.
// NodeCalendarContractVectorTests enforces an exact copy; regenerate on change.
enum NodeCalendarSchemaSource {
    static let json = #"""
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://plainpost.app/protocol/node-calendar-v1/node-calendar.schema.json",
  "title": "Plainpost closed node-calendar-v1 wire object",
  "oneOf": [
    {
      "$ref": "#/$defs/windowRequest"
    },
    {
      "$ref": "#/$defs/windowResult"
    },
    {
      "$ref": "#/$defs/commandRequest"
    },
    {
      "$ref": "#/$defs/commandResult"
    },
    {
      "$ref": "#/$defs/receiptRequest"
    },
    {
      "$ref": "#/$defs/receiptResult"
    },
    {
      "$ref": "#/$defs/invitationRequest"
    },
    {
      "$ref": "#/$defs/invitationResult"
    },
    {
      "$ref": "#/$defs/problem"
    },
    {
      "$ref": "#/$defs/capabilities"
    },
    {
      "$ref": "#/$defs/connectionsRequest"
    },
    {
      "$ref": "#/$defs/connectionsResult"
    },
    {
      "$ref": "#/$defs/connectionRequest"
    },
    {
      "$ref": "#/$defs/disconnectRequest"
    },
    {
      "$ref": "#/$defs/connectionResult"
    },
    {
      "$ref": "#/$defs/eventRequest"
    },
    {
      "$ref": "#/$defs/eventResult"
    },
    {
      "$ref": "#/$defs/invitationReadRequest"
    },
    {
      "$ref": "#/$defs/invitationReadResult"
    },
    {
      "$ref": "#/$defs/operationReadRequest"
    },
    {
      "$ref": "#/$defs/operationReadResult"
    },
    {
      "$ref": "#/$defs/receipt"
    }
  ],
  "$defs": {
    "identifier": {
      "type": "string",
      "minLength": 1,
      "maxLength": 512,
      "pattern": "^[^\\u0000]*$"
    },
    "opaqueCursor": {
      "type": "string",
      "maxLength": 4096,
      "pattern": "^[^\\u0000]*$"
    },
    "counter": {
      "type": "integer",
      "minimum": 0,
      "maximum": 9007199254740991
    },
    "timestamp": {
      "type": "string",
      "format": "date-time"
    },
    "timezone": {
      "type": "string",
      "minLength": 1,
      "maxLength": 255,
      "pattern": "^[A-Za-z0-9_+/-]+$"
    },
    "calendarTime": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "timezone",
        "value"
      ],
      "properties": {
        "kind": {
          "enum": [
            "date",
            "date_time"
          ]
        },
        "value": {
          "type": "string",
          "minLength": 1,
          "maxLength": 64
        },
        "timezone": {
          "$ref": "#/$defs/timezone"
        }
      }
    },
    "floatingTime": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "timezone",
        "value"
      ],
      "properties": {
        "kind": {
          "const": "date_time"
        },
        "value": {
          "type": "string",
          "minLength": 19,
          "maxLength": 19
        },
        "timezone": {
          "const": ""
        }
      }
    },
    "eventTime": {
      "oneOf": [
        {
          "$ref": "#/$defs/calendarTime"
        },
        {
          "$ref": "#/$defs/floatingTime"
        }
      ]
    },
    "editTime": {
      "oneOf": [
        {
          "$ref": "#/$defs/calendarTime"
        },
        {
          "$ref": "#/$defs/unchangedTime"
        }
      ]
    },
    "unchangedTime": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "timezone",
        "value"
      ],
      "properties": {
        "kind": {
          "const": "date_time"
        },
        "value": {
          "const": ""
        },
        "timezone": {
          "const": ""
        }
      }
    },
    "eventKey": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "accountID",
        "calendarID",
        "connectionID",
        "organizer",
        "providerID",
        "recurrenceID",
        "uid"
      ],
      "properties": {
        "accountID": {
          "$ref": "#/$defs/identifier"
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "calendarID": {
          "$ref": "#/$defs/identifier"
        },
        "providerID": {
          "$ref": "#/$defs/identifier"
        },
        "uid": {
          "$ref": "#/$defs/identifier"
        },
        "organizer": {
          "type": "string",
          "maxLength": 512
        },
        "recurrenceID": {
          "type": "string",
          "maxLength": 128
        }
      }
    },
    "event": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "attendeeAddress",
        "canEditOccurrence",
        "canEditSeries",
        "canRespond",
        "cancelled",
        "disabledReason",
        "end",
        "id",
        "key",
        "location",
        "messageID",
        "notes",
        "providerLink",
        "recurring",
        "response",
        "revision",
        "sequence",
        "stamp",
        "start",
        "threadID",
        "title"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "key": {
          "$ref": "#/$defs/eventKey"
        },
        "revision": {
          "type": "string",
          "maxLength": 512
        },
        "sequence": {
          "$ref": "#/$defs/counter"
        },
        "stamp": {
          "type": "string",
          "maxLength": 128
        },
        "title": {
          "type": "string",
          "maxLength": 65536
        },
        "location": {
          "type": "string",
          "maxLength": 65536
        },
        "notes": {
          "type": "string",
          "maxLength": 1048576
        },
        "start": {
          "$ref": "#/$defs/eventTime"
        },
        "end": {
          "$ref": "#/$defs/eventTime"
        },
        "recurring": {
          "type": "boolean"
        },
        "cancelled": {
          "type": "boolean"
        },
        "attendeeAddress": {
          "type": "string",
          "maxLength": 512
        },
        "response": {
          "enum": [
            "",
            "needsAction",
            "accepted",
            "tentative",
            "declined"
          ]
        },
        "canEditOccurrence": {
          "type": "boolean"
        },
        "canEditSeries": {
          "type": "boolean"
        },
        "canRespond": {
          "type": "boolean"
        },
        "disabledReason": {
          "type": "string",
          "maxLength": 512
        },
        "threadID": {
          "type": "string",
          "maxLength": 512
        },
        "messageID": {
          "type": "string",
          "maxLength": 512
        },
        "providerLink": {
          "type": "string",
          "maxLength": 2048
        }
      }
    },
    "connection": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "accountID",
        "attendeeAddress",
        "delivery",
        "enabled",
        "endpoint",
        "generation",
        "id",
        "kind",
        "sendingMailbox",
        "username"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "accountID": {
          "$ref": "#/$defs/identifier"
        },
        "generation": {
          "$ref": "#/$defs/counter"
        },
        "kind": {
          "enum": [
            "google",
            "caldav"
          ]
        },
        "endpoint": {
          "type": "string",
          "maxLength": 2048
        },
        "username": {
          "type": "string",
          "maxLength": 512
        },
        "sendingMailbox": {
          "type": "string",
          "maxLength": 128
        },
        "attendeeAddress": {
          "type": "string",
          "maxLength": 512
        },
        "delivery": {
          "enum": [
            "google",
            "caldav_server",
            "email"
          ]
        },
        "enabled": {
          "type": "boolean"
        }
      }
    },
    "collection": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "color",
        "connectionID",
        "id",
        "name",
        "providerID",
        "scheduling",
        "syncCollection",
        "timezone",
        "writable"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "providerID": {
          "$ref": "#/$defs/identifier"
        },
        "name": {
          "type": "string",
          "maxLength": 512
        },
        "color": {
          "type": "string",
          "maxLength": 64
        },
        "timezone": {
          "$ref": "#/$defs/timezone"
        },
        "writable": {
          "type": "boolean"
        },
        "scheduling": {
          "type": "boolean"
        },
        "syncCollection": {
          "type": "boolean"
        }
      }
    },
    "window": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "end",
        "start",
        "timezone"
      ],
      "properties": {
        "start": {
          "$ref": "#/$defs/timestamp"
        },
        "end": {
          "$ref": "#/$defs/timestamp"
        },
        "timezone": {
          "$ref": "#/$defs/timezone"
        }
      }
    },
    "resource": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "accountID",
        "calendarID",
        "connectionID",
        "data",
        "deleted",
        "kind",
        "providerID",
        "revision",
        "scheduleTag"
      ],
      "properties": {
        "accountID": {
          "$ref": "#/$defs/identifier"
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "kind": {
          "enum": [
            "google",
            "caldav"
          ]
        },
        "calendarID": {
          "$ref": "#/$defs/identifier"
        },
        "providerID": {
          "$ref": "#/$defs/identifier"
        },
        "revision": {
          "type": "string",
          "maxLength": 512
        },
        "scheduleTag": {
          "type": "string",
          "maxLength": 512
        },
        "data": {
          "type": "string",
          "contentEncoding": "base64",
          "maxLength": 8388608
        },
        "deleted": {
          "type": "boolean"
        }
      }
    },
    "batch": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "checkpoint",
        "complete",
        "resources"
      ],
      "properties": {
        "resources": {
          "type": "array",
          "maxItems": 10000,
          "items": {
            "$ref": "#/$defs/resource"
          }
        },
        "checkpoint": {
          "type": "string",
          "maxLength": 4096
        },
        "complete": {
          "type": "boolean"
        }
      }
    },
    "edit": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "end",
        "location",
        "notes",
        "start",
        "title"
      ],
      "properties": {
        "title": {
          "type": "string",
          "maxLength": 65536
        },
        "location": {
          "type": "string",
          "maxLength": 65536
        },
        "notes": {
          "type": "string",
          "maxLength": 1048576
        },
        "start": {
          "$ref": "#/$defs/editTime"
        },
        "end": {
          "$ref": "#/$defs/editTime"
        }
      }
    },
    "command": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "connectionID",
        "eventID",
        "generation",
        "invitationID",
        "operationID",
        "revision",
        "scope"
      ],
      "oneOf": [
        {
          "required": [
            "edit"
          ],
          "not": {
            "required": [
              "response"
            ]
          },
          "properties": {
            "invitationID": {
              "const": ""
            }
          }
        },
        {
          "required": [
            "response"
          ],
          "not": {
            "required": [
              "edit"
            ]
          },
          "properties": {
            "invitationID": {
              "$ref": "#/$defs/identifier"
            }
          }
        }
      ],
      "properties": {
        "operationID": {
          "$ref": "#/$defs/identifier"
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "generation": {
          "$ref": "#/$defs/counter"
        },
        "eventID": {
          "$ref": "#/$defs/identifier"
        },
        "invitationID": {
          "type": "string",
          "maxLength": 512
        },
        "revision": {
          "$ref": "#/$defs/identifier"
        },
        "scope": {
          "enum": [
            "occurrence",
            "series"
          ]
        },
        "edit": {
          "$ref": "#/$defs/edit"
        },
        "response": {
          "enum": [
            "needsAction",
            "accepted",
            "tentative",
            "declined"
          ]
        },
        "targetCalendarID": {
          "$ref": "#/$defs/identifier"
        }
      }
    },
    "receipt": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "calendar",
        "code",
        "delivery",
        "eventID",
        "operationID",
        "owner",
        "revision"
      ],
      "properties": {
        "operationID": {
          "$ref": "#/$defs/identifier"
        },
        "owner": {
          "enum": [
            "google",
            "caldav_server",
            "email"
          ]
        },
        "calendar": {
          "enum": [
            "not_needed",
            "pending",
            "in_flight",
            "confirmed",
            "failed",
            "uncertain"
          ]
        },
        "delivery": {
          "enum": [
            "not_needed",
            "pending",
            "in_flight",
            "confirmed",
            "failed",
            "uncertain"
          ]
        },
        "code": {
          "type": "string",
          "maxLength": 512
        },
        "eventID": {
          "$ref": "#/$defs/identifier"
        },
        "revision": {
          "type": "string",
          "maxLength": 512
        }
      }
    },
    "invitation": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "attendeeAddress",
        "eventID",
        "id",
        "messageID",
        "method",
        "organizer",
        "recurrenceID",
        "revision",
        "sequence",
        "stamp",
        "state",
        "uid"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "eventID": {
          "$ref": "#/$defs/identifier"
        },
        "messageID": {
          "$ref": "#/$defs/identifier"
        },
        "uid": {
          "$ref": "#/$defs/identifier"
        },
        "organizer": {
          "type": "string",
          "maxLength": 512
        },
        "attendeeAddress": {
          "type": "string",
          "maxLength": 512
        },
        "recurrenceID": {
          "type": "string",
          "maxLength": 128
        },
        "method": {
          "type": "string",
          "maxLength": 32
        },
        "revision": {
          "type": "string",
          "maxLength": 512
        },
        "state": {
          "enum": [
            "actionable",
            "superseded",
            "cancelled",
            "unresolved",
            "informational"
          ]
        },
        "sequence": {
          "$ref": "#/$defs/counter"
        },
        "stamp": {
          "type": "string",
          "maxLength": 128
        }
      }
    },
    "windowRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "window",
        "cursor"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.window-request.v1"
        },
        "window": {
          "$ref": "#/$defs/window"
        },
        "cursor": {
          "$ref": "#/$defs/opaqueCursor"
        },
        "refresh": {
          "const": true
        }
      }
    },
    "windowResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "coverage",
        "events",
        "failures",
        "kind",
        "refreshedAt",
        "window",
        "nextCursor"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.window-result.v1"
        },
        "events": {
          "type": "array",
          "maxItems": 10000,
          "items": {
            "anyOf": [
              {
                "$ref": "#/$defs/event"
              },
              {
                "$ref": "#/$defs/nativeEvent"
              }
            ]
          }
        },
        "window": {
          "$ref": "#/$defs/window"
        },
        "coverage": {
          "type": "string",
          "maxLength": 512
        },
        "refreshedAt": {
          "$ref": "#/$defs/timestamp"
        },
        "failures": {
          "type": "object",
          "additionalProperties": {
            "type": "string",
            "maxLength": 512
          },
          "propertyNames": {
            "$ref": "#/$defs/identifier"
          }
        },
        "nextCursor": {
          "$ref": "#/$defs/opaqueCursor"
        }
      }
    },
    "commandRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "command",
        "kind"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.command-request.v1"
        },
        "command": {
          "$ref": "#/$defs/command"
        }
      }
    },
    "commandResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "receipt"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.command-result.v1"
        },
        "receipt": {
          "$ref": "#/$defs/receipt"
        }
      }
    },
    "receiptRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "operationID"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.receipt-request.v1"
        },
        "operationID": {
          "$ref": "#/$defs/identifier"
        }
      }
    },
    "receiptResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "receipt"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.receipt-result.v1"
        },
        "receipt": {
          "$ref": "#/$defs/receipt"
        }
      }
    },
    "invitationRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "kind"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.invitation-request.v1"
        },
        "id": {
          "$ref": "#/$defs/identifier"
        }
      }
    },
    "invitationResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "invitation",
        "kind"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.invitation-result.v1"
        },
        "invitation": {
          "$ref": "#/$defs/invitation"
        }
      }
    },
    "problem": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "category",
        "kind"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.problem.v1"
        },
        "category": {
          "enum": [
            "invalid_request",
            "unauthorized",
            "conflict",
            "not_found",
            "unavailable"
          ]
        },
        "code": {
          "enum": [
            "target_calendar_required",
            "snapshot_changed",
            "calendar_index_pending"
          ]
        }
      }
    },
    "nativeEvent": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "attendeeAddress",
        "canEditOccurrence",
        "canEditSeries",
        "canRespond",
        "cancelled",
        "disabledReason",
        "end",
        "id",
        "location",
        "messageID",
        "notes",
        "providerLink",
        "recurring",
        "response",
        "revision",
        "sequence",
        "stamp",
        "start",
        "threadID",
        "title",
        "connectionID",
        "calendarID",
        "recurrenceID",
        "organizer"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "revision": {
          "type": "string",
          "maxLength": 512
        },
        "sequence": {
          "$ref": "#/$defs/counter"
        },
        "stamp": {
          "type": "string",
          "maxLength": 128
        },
        "title": {
          "type": "string",
          "maxLength": 65536
        },
        "location": {
          "type": "string",
          "maxLength": 65536
        },
        "notes": {
          "type": "string",
          "maxLength": 1048576
        },
        "start": {
          "$ref": "#/$defs/eventTime"
        },
        "end": {
          "$ref": "#/$defs/eventTime"
        },
        "recurring": {
          "type": "boolean"
        },
        "cancelled": {
          "type": "boolean"
        },
        "attendeeAddress": {
          "type": "string",
          "maxLength": 512
        },
        "response": {
          "enum": [
            "",
            "needsAction",
            "accepted",
            "tentative",
            "declined"
          ]
        },
        "canEditOccurrence": {
          "type": "boolean"
        },
        "canEditSeries": {
          "type": "boolean"
        },
        "canRespond": {
          "type": "boolean"
        },
        "disabledReason": {
          "type": "string",
          "maxLength": 512
        },
        "threadID": {
          "type": "string",
          "maxLength": 512
        },
        "messageID": {
          "type": "string",
          "maxLength": 512
        },
        "providerLink": {
          "type": "string",
          "maxLength": 2048
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "calendarID": {
          "$ref": "#/$defs/identifier"
        },
        "recurrenceID": {
          "type": "string",
          "maxLength": 512
        },
        "organizer": {
          "type": "string",
          "maxLength": 512
        }
      }
    },
    "nativeConnection": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "generation",
        "kind",
        "sendingMailbox",
        "attendeeAddress",
        "delivery",
        "enabled",
        "calendars"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "generation": {
          "$ref": "#/$defs/counter"
        },
        "kind": {
          "enum": [
            "google",
            "caldav"
          ]
        },
        "sendingMailbox": {
          "type": "string",
          "maxLength": 128
        },
        "attendeeAddress": {
          "type": "string",
          "maxLength": 512
        },
        "delivery": {
          "enum": [
            "google",
            "caldav_server",
            "email"
          ]
        },
        "enabled": {
          "type": "boolean"
        },
        "calendars": {
          "type": "array",
          "maxItems": 200,
          "items": {
            "$ref": "#/$defs/nativeCollection"
          }
        }
      }
    },
    "googleConfiguration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "authorizationCode",
        "codeVerifier",
        "clientID",
        "redirectURI"
      ],
      "properties": {
        "authorizationCode": {
          "type": "string",
          "maxLength": 4096
        },
        "codeVerifier": {
          "type": "string",
          "maxLength": 2048
        },
        "clientID": {
          "type": "string",
          "maxLength": 2048
        },
        "redirectURI": {
          "type": "string",
          "maxLength": 2048
        }
      }
    },
    "caldavConfiguration": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "endpoint",
        "username",
        "password",
        "approvedRedirectOrigins"
      ],
      "properties": {
        "endpoint": {
          "type": "string",
          "maxLength": 2048
        },
        "username": {
          "type": "string",
          "maxLength": 512
        },
        "password": {
          "type": "string",
          "maxLength": 16384
        },
        "approvedRedirectOrigins": {
          "type": "array",
          "maxItems": 16,
          "items": {
            "type": "string",
            "maxLength": 2048
          }
        }
      }
    },
    "configuration": {
      "oneOf": [
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "google"
          ],
          "properties": {
            "google": {
              "$ref": "#/$defs/googleConfiguration"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "caldav"
          ],
          "properties": {
            "caldav": {
              "$ref": "#/$defs/caldavConfiguration"
            }
          }
        }
      ]
    },
    "connectionCommand": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "operationID",
        "expectedGeneration",
        "kind",
        "configuration",
        "sendingMailboxID",
        "attendeeAddress"
      ],
      "properties": {
        "operationID": {
          "$ref": "#/$defs/identifier"
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "expectedGeneration": {
          "$ref": "#/$defs/counter"
        },
        "kind": {
          "enum": [
            "google",
            "caldav"
          ]
        },
        "configuration": {
          "$ref": "#/$defs/configuration"
        },
        "sendingMailboxID": {
          "type": [
            "string",
            "null"
          ],
          "maxLength": 128
        },
        "attendeeAddress": {
          "type": [
            "string",
            "null"
          ],
          "maxLength": 512
        }
      },
      "oneOf": [
        {
          "properties": {
            "kind": {
              "const": "google"
            },
            "configuration": {
              "required": [
                "google"
              ]
            }
          }
        },
        {
          "properties": {
            "kind": {
              "const": "caldav"
            },
            "configuration": {
              "required": [
                "caldav"
              ]
            }
          }
        }
      ]
    },
    "capabilities": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "enabled",
        "version",
        "providers",
        "google"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.capabilities.v1"
        },
        "enabled": {
          "type": "boolean"
        },
        "version": {
          "$ref": "#/$defs/counter"
        },
        "providers": {
          "type": "array",
          "uniqueItems": true,
          "items": {
            "enum": [
              "google",
              "caldav"
            ]
          }
        },
        "google": {
          "$ref": "#/$defs/googleAvailability"
        }
      }
    },
    "googleAvailability": {
      "oneOf": [
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "configured",
            "clientID"
          ],
          "properties": {
            "configured": {
              "type": "boolean",
              "const": true
            },
            "clientID": {
              "$ref": "#/$defs/identifier"
            }
          }
        },
        {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "configured",
            "clientID"
          ],
          "properties": {
            "configured": {
              "type": "boolean",
              "const": false
            },
            "clientID": {
              "type": "null"
            }
          }
        }
      ]
    },
    "connectionsRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.connections-request.v1"
        }
      }
    },
    "connectionsResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "connections"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.connections-result.v1"
        },
        "connections": {
          "type": "array",
          "maxItems": 200,
          "items": {
            "$ref": "#/$defs/nativeConnection"
          }
        }
      }
    },
    "connectionRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "command"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.connection-command.v1"
        },
        "command": {
          "$ref": "#/$defs/connectionCommand"
        }
      }
    },
    "disconnectRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "operationID",
        "connectionID",
        "expectedGeneration"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.disconnect-command.v1"
        },
        "operationID": {
          "$ref": "#/$defs/identifier"
        },
        "connectionID": {
          "$ref": "#/$defs/identifier"
        },
        "expectedGeneration": {
          "$ref": "#/$defs/counter"
        }
      }
    },
    "connectionResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "operationID",
        "connection",
        "state",
        "code"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.connection-result.v1"
        },
        "operationID": {
          "$ref": "#/$defs/identifier"
        },
        "connection": {
          "$ref": "#/$defs/nativeConnection"
        },
        "state": {
          "enum": [
            "not_needed",
            "pending",
            "in_flight",
            "confirmed",
            "failed",
            "uncertain"
          ]
        },
        "code": {
          "enum": [
            "",
            "calendar_limit",
            "calendar_metadata_limit"
          ]
        }
      }
    },
    "eventRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "eventID"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.event-request.v1"
        },
        "eventID": {
          "$ref": "#/$defs/identifier"
        }
      }
    },
    "eventResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "event"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.event-result.v1"
        },
        "event": {
          "$ref": "#/$defs/nativeEvent"
        }
      }
    },
    "invitationReadRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "messageIDs"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.invitation-read-request.v1"
        },
        "messageIDs": {
          "type": "array",
          "maxItems": 200,
          "uniqueItems": true,
          "items": {
            "$ref": "#/$defs/identifier"
          }
        }
      }
    },
    "invitationReadResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "invitations"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.invitation-read-result.v1"
        },
        "invitations": {
          "type": "array",
          "maxItems": 200,
          "items": {
            "$ref": "#/$defs/nativeInvitation"
          }
        }
      }
    },
    "operationReadRequest": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "operationIDs"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.operation-read-request.v1"
        },
        "operationIDs": {
          "type": "array",
          "maxItems": 200,
          "uniqueItems": true,
          "items": {
            "$ref": "#/$defs/identifier"
          }
        }
      }
    },
    "operationReadResult": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "kind",
        "receipts",
        "unknownOperationIDs"
      ],
      "properties": {
        "kind": {
          "const": "node-calendar.operation-read-result.v1"
        },
        "receipts": {
          "type": "array",
          "maxItems": 200,
          "items": {
            "$ref": "#/$defs/receipt"
          }
        },
        "unknownOperationIDs": {
          "type": "array",
          "maxItems": 200,
          "uniqueItems": true,
          "items": {
            "$ref": "#/$defs/identifier"
          }
        }
      }
    },
    "nativeCollection": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "name",
        "color",
        "timezone",
        "writable",
        "scheduling"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "name": {
          "type": "string",
          "maxLength": 512
        },
        "color": {
          "type": "string",
          "maxLength": 64
        },
        "timezone": {
          "anyOf": [
            {
              "const": ""
            },
            {
              "$ref": "#/$defs/timezone"
            }
          ]
        },
        "writable": {
          "type": "boolean"
        },
        "scheduling": {
          "type": "boolean"
        }
      }
    },
    "nativeInvitation": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "attendeeAddress",
        "eventID",
        "id",
        "messageID",
        "method",
        "organizer",
        "recurrenceID",
        "revision",
        "sequence",
        "stamp",
        "state",
        "uid",
        "title",
        "location",
        "start",
        "end",
        "meetingURL",
        "calendarEventID"
      ],
      "properties": {
        "id": {
          "$ref": "#/$defs/identifier"
        },
        "eventID": {
          "$ref": "#/$defs/identifier"
        },
        "messageID": {
          "$ref": "#/$defs/identifier"
        },
        "uid": {
          "$ref": "#/$defs/identifier"
        },
        "organizer": {
          "type": "string",
          "maxLength": 512
        },
        "attendeeAddress": {
          "type": "string",
          "maxLength": 512
        },
        "recurrenceID": {
          "type": "string",
          "maxLength": 128
        },
        "method": {
          "type": "string",
          "maxLength": 32
        },
        "revision": {
          "type": "string",
          "maxLength": 512
        },
        "state": {
          "enum": [
            "actionable",
            "superseded",
            "cancelled",
            "unresolved",
            "informational"
          ]
        },
        "sequence": {
          "$ref": "#/$defs/counter"
        },
        "stamp": {
          "type": "string",
          "maxLength": 128
        },
        "title": {
          "type": "string",
          "maxLength": 512
        },
        "location": {
          "type": "string",
          "maxLength": 512
        },
        "start": {
          "oneOf": [
            {
              "type": "null"
            },
            {
              "$ref": "#/$defs/eventTime"
            }
          ]
        },
        "end": {
          "oneOf": [
            {
              "type": "null"
            },
            {
              "$ref": "#/$defs/eventTime"
            }
          ]
        },
        "meetingURL": {
          "type": [
            "string",
            "null"
          ],
          "maxLength": 1024
        },
        "calendarEventID": {
          "oneOf": [
            {
              "type": "null"
            },
            {
              "$ref": "#/$defs/identifier"
            }
          ]
        }
      }
    }
  }
}
"""#
}
