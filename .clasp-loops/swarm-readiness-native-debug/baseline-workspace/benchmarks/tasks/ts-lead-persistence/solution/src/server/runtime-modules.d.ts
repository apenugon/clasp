declare module "node:module" {
  export function createRequire(
    filename: string | URL
  ): (id: string) => unknown;
}

declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(location: string);
    close(): void;
    exec(sql: string): void;
    prepare(sql: string): {
      all(...parameters: unknown[]): unknown[];
      get(...parameters: unknown[]): unknown;
      run(...parameters: unknown[]): {
        changes: number;
        lastInsertRowid: number | bigint;
      };
    };
  }
}

declare module "bun:sqlite" {
  export class Database {
    constructor(location: string);
    close(): void;
    exec(sql: string): void;
    query(sql: string): {
      all(...parameters: unknown[]): unknown[];
      get(...parameters: unknown[]): unknown;
      run(...parameters: unknown[]): {
        changes: number;
        lastInsertRowid: number | bigint;
      };
    };
  }
}
