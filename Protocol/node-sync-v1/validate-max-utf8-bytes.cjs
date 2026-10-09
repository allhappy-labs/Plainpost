// Local Ajv keyword for the protocol's byte (not Unicode-scalar) ceilings.
module.exports = function installPlainpostMaxUTF8Bytes(ajv) {
  ajv.addKeyword({
    keyword: "x-plainpost-maxUtf8Bytes",
    type: "string",
    schemaType: "number",
    errors: true,
    validate(limit, value) {
      const valid = Buffer.byteLength(value, "utf8") <= limit;
      if (!valid) {
        installPlainpostMaxUTF8Bytes.errors = [{
          keyword: "x-plainpost-maxUtf8Bytes",
          message: "must not exceed " + limit + " UTF-8 bytes",
          params: { limit }
        }];
      }
      return valid;
    }
  });
  ajv.addKeyword({
    keyword: "x-plainpost-maxCanonicalBytes",
    type: "object",
    schemaType: "number",
    errors: true,
    validate(limit, value) {
      const canonical = JSON.stringify(value)
        .replace(/\u2028/g, "\\u2028")
        .replace(/\u2029/g, "\\u2029");
      const valid = Buffer.byteLength(canonical, "utf8") <= limit;
      if (!valid) {
        installPlainpostMaxUTF8Bytes.errors = [{
          keyword: "x-plainpost-maxCanonicalBytes",
          message: "must not exceed " + limit + " canonical JSON bytes",
          params: { limit }
        }];
      }
      return valid;
    }
  });
};
