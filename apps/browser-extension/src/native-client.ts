export function withTimeout<T>(promise: Promise<T>, milliseconds: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("NATIVE_MESSAGE_TIMEOUT")), milliseconds);
    promise.then(
      (value) => { clearTimeout(timer); resolve(value); },
      (error: unknown) => { clearTimeout(timer); reject(error); },
    );
  });
}

export function mapNativeFailure(error: unknown): { code: "NATIVE_MESSAGE_TIMEOUT" | "NATIVE_HOST_NOT_FOUND"; action: "retry" | "open_install_guide" } {
  const timedOut = error instanceof Error && error.message.includes("NATIVE_MESSAGE_TIMEOUT");
  return timedOut
    ? { code: "NATIVE_MESSAGE_TIMEOUT", action: "retry" }
    : { code: "NATIVE_HOST_NOT_FOUND", action: "open_install_guide" };
}
