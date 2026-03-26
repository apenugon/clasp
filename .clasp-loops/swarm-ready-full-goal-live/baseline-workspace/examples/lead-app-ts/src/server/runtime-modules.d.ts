declare const Bun: object | undefined;

declare module "node:module" {
  export function createRequire(
    filename: string | URL
  ): (specifier: string) => unknown;
}

declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(location: string);
    close(): void;
    exec(sql: string): void;
    prepare(sql: string): StatementSync;
  }

  export interface StatementSync {
    all(...parameters: unknown[]): unknown[];
    get(...parameters: unknown[]): unknown;
    run(...parameters: unknown[]): {
      changes: number;
      lastInsertRowid: number | bigint;
    };
  }
}

declare module "bun:sqlite" {
  export class Database {
    constructor(location: string);
    close(): void;
    exec(sql: string): void;
    query(sql: string): Statement;
  }

  export interface Statement {
    all(...parameters: unknown[]): unknown[];
    get(...parameters: unknown[]): unknown;
    run(...parameters: unknown[]): {
      changes: number;
      lastInsertRowid: number | bigint;
    };
  }
}
