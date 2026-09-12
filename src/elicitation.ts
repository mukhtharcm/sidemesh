import type { PendingActionElicitationField } from "./types.js";

/** Common MCP/ACP JSON schema subset supported by the app's form controls. */
export function elicitationFields(schema: unknown): PendingActionElicitationField[] {
  if (!isRecord(schema) || schema.type !== "object" || !isRecord(schema.properties)) return [];
  const required = new Set(Array.isArray(schema.required) ? schema.required : []);
  return Object.entries(schema.properties).flatMap(([key, value]): PendingActionElicitationField[] => {
    if (!isRecord(value)) return [];
    const base = {
      key, title: typeof value.title === "string" && value.title.trim() ? value.title : key,
      description: typeof value.description === "string" ? value.description : undefined,
      required: required.has(key),
    };
    if (value.type === "boolean") return [{
      ...base, type: "boolean",
      ...(typeof value.default === "boolean" ? { defaultValue: value.default } : {}),
    }];
    if (value.type === "number" || value.type === "integer") return [{
      ...base, type: "number", integer: value.type === "integer",
      ...(typeof value.default === "number" ? { defaultValue: value.default } : {}),
      ...(typeof value.minimum === "number" ? { minimum: value.minimum } : {}),
      ...(typeof value.maximum === "number" ? { maximum: value.maximum } : {}),
    }];
    if (value.type === "array" && isRecord(value.items)) return [{
      ...base, type: "string[]", options: choices(value.items) ?? [],
      ...(Array.isArray(value.default) && value.default.every((item) => typeof item === "string")
        ? { defaultValue: value.default } : {}),
      ...(typeof value.minItems === "number" ? { minItems: value.minItems } : {}),
      ...(typeof value.maxItems === "number" ? { maxItems: value.maxItems } : {}),
    }];
    if (value.type != null && value.type !== "string") return [];
    const options = choices(value);
    const format = value.format;
    return [{
      ...base, type: "string",
      ...(typeof value.default === "string" ? { defaultValue: value.default } : {}),
      ...(options?.length ? { options } : {}),
      ...(typeof value.minLength === "number" ? { minLength: value.minLength } : {}),
      ...(typeof value.maxLength === "number" ? { maxLength: value.maxLength } : {}),
      ...(format === "email" || format === "uri" || format === "date" || format === "date-time" ? { format } : {}),
    }];
  });
}

function choices(field: Record<string, unknown>): Array<{ value: string; label: string }> | undefined {
  if (Array.isArray(field.enum)) return field.enum.flatMap((value, index) => typeof value !== "string" ? [] : [{
    value, label: Array.isArray(field.enumNames) && typeof field.enumNames[index] === "string"
      && field.enumNames[index].trim() ? field.enumNames[index] : value,
  }]);
  const variants = field.oneOf ?? field.anyOf;
  if (!Array.isArray(variants)) return undefined;
  return variants.flatMap((item) => isRecord(item) && typeof item.const === "string" ? [{
    value: item.const, label: typeof item.title === "string" && item.title ? item.title : item.const,
  }] : []);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
