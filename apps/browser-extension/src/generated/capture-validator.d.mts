export type SchemaValidationError = {
  instancePath: string;
  keyword: string;
};

export type CaptureSchemaValidator = {
  (value: unknown): boolean;
  errors?: SchemaValidationError[] | null;
};

declare const validate: CaptureSchemaValidator;
export { validate };
export default validate;
