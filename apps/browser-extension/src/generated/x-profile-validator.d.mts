export type SchemaValidationError = {
  instancePath: string;
  keyword: string;
};

export type XProfileSchemaValidator = {
  (value: unknown): boolean;
  errors?: SchemaValidationError[] | null;
};

declare const validate: XProfileSchemaValidator;
export { validate };
export default validate;
