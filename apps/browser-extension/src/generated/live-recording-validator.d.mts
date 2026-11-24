export type SchemaValidationError = {
  instancePath: string;
  keyword: string;
};

export type LiveRecordingSchemaValidator = {
  (value: unknown): boolean;
  errors?: SchemaValidationError[] | null;
};

declare const validate: LiveRecordingSchemaValidator;
export { validate };
export default validate;
