import { DatabaseSync } from "node:sqlite";

export function installRuntime(bindings) {
  const previous = globalThis.__claspRuntime ?? {};
  globalThis.__claspRuntime = {
    ...previous,
    ...bindings
  };
}

export function bindingContractFor(compiledModule) {
  const contract = compiledModule?.__claspBindings;

  if (
    contract &&
    contract.kind === "clasp-generated-bindings" &&
    contract.version === 1
  ) {
    const hostBindings = contract.hostBindings ?? compiledModule?.__claspHostBindings ?? [];
    return {
      ...contract,
      module: contract.module ?? compiledModule?.__claspModule ?? null,
      hostBindings,
      providers:
        contract.providers ?? defaultProviderContract(compiledModule, hostBindings),
      storage:
        contract.storage ?? defaultStorageContract(compiledModule, hostBindings),
      sqlite: contract.sqlite ?? defaultSqliteContract(hostBindings),
      nativeInterop:
        contract.nativeInterop ??
        compiledModule?.__claspNativeInterop ??
        defaultNativeInterop(hostBindings),
      air: contract.air ?? compiledModule?.__claspAir ?? null,
      airProjectors: contract.airProjectors ?? compiledModule?.__claspAirProjectors ?? null,
      evalHooks: contract.evalHooks ?? compiledModule?.__claspEvalHooks ?? null,
      traces: contract.traces ?? compiledModule?.__claspTraceCollector ?? null,
      traceability:
        contract.traceability ?? compiledModule?.__claspTraceability ?? null
    };
  }

  const hostBindings = compiledModule?.__claspHostBindings ?? [];

  return {
    kind: "clasp-generated-bindings",
    version: 1,
    module: compiledModule?.__claspModule ?? null,
    hostBindings,
    providers: defaultProviderContract(compiledModule, hostBindings),
    storage: defaultStorageContract(compiledModule, hostBindings),
    sqlite: defaultSqliteContract(hostBindings),
    nativeInterop:
      compiledModule?.__claspNativeInterop ??
      defaultNativeInterop(hostBindings),
    packageImports: compiledModule?.__claspPackageImports ?? [],
    routes: compiledModule?.__claspRoutes ?? [],
    routeClients: compiledModule?.__claspRouteClients ?? [],
    schemas: compiledModule?.__claspSchemas ?? {},
    platformBridges:
      compiledModule?.__claspPlatformBridges ?? defaultPlatformBridges(),
    python: compiledModule?.__claspPythonInterop ?? null,
    seededFixtures: compiledModule?.__claspSeededFixtures ?? [],
    staticAssetStrategy:
      compiledModule?.__claspStaticAssetStrategy ?? {
        assetBasePath: "/assets",
        generatedAssetBasePath: "/assets/clasp"
      },
    staticAssets: compiledModule?.__claspStaticAssets ?? [],
    styleIR: compiledModule?.__claspStyleIR ?? null,
    styleBundles: compiledModule?.__claspStyleBundles ?? [],
    headStrategy:
      compiledModule?.__claspHeadStrategy ?? {
        charset: "utf-8",
        viewport: "width=device-width, initial-scale=1"
      },
    uiGraph: compiledModule?.__claspUiGraph ?? [],
    navigationGraph: compiledModule?.__claspNavigationGraph ?? [],
    actionGraph: compiledModule?.__claspActionGraph ?? [],
    air: compiledModule?.__claspAir ?? null,
    airProjectors: compiledModule?.__claspAirProjectors ?? null,
    evalHooks: compiledModule?.__claspEvalHooks ?? null,
    traces: compiledModule?.__claspTraceCollector ?? null,
    traceability: compiledModule?.__claspTraceability ?? null
  };
}

export function schemaContractFor(compiledModule, typeName) {
  const contract = bindingContractFor(compiledModule);
  const schema = contract.schemas?.[typeName];

  if (!schema) {
    throw new Error(`Missing Clasp schema contract: ${typeName}`);
  }

  return schema;
}

export function createDynamicSchema(compiledModule, typeNames) {
  const normalizedTypeNames = normalizeDynamicSchemaTypeNames(typeNames);
  const entries = normalizedTypeNames.map((typeName) => [
    typeName,
    schemaContractFor(compiledModule, typeName)
  ]);
  const schemaMap = new Map(entries);
  const schemas = Object.freeze(
    Object.fromEntries(entries.map(([typeName, contract]) => [typeName, contract.schema ?? null]))
  );
  const seeds = Object.freeze(
    Object.fromEntries(entries.map(([typeName, contract]) => [typeName, contract.seed ?? null]))
  );

  return Object.freeze({
    kind: "clasp-dynamic-schema",
    version: 1,
    schemaNames: Object.freeze(normalizedTypeNames),
    schemas,
    seeds,
    schema(typeName) {
      const contract = schemaMap.get(typeName);

      if (!contract) {
        throw new Error(
          `Dynamic schema does not allow ${String(typeName)}. Expected one of: ${normalizedTypeNames.join(", ")}`
        );
      }

      return contract;
    },
    match(value, path = "value") {
      return selectDynamicSchemaMatch(entries, value, path);
    },
    select(value, path = "value") {
      return this.match(value, path);
    },
    decodeJson(jsonText, path = "value") {
      return selectDynamicSchemaDecode(entries, jsonText, path).value;
    },
    selectJson(jsonText, path = "value") {
      return selectDynamicSchemaDecode(entries, jsonText, path);
    },
    encodeJson(value, path = "value") {
      const selection = this.match(value, path);
      return selection.schema.encodeJson(selection.value);
    }
  });
}

export function createBamlShim(compiledModule, options = {}) {
  const contract = bindingContractFor(compiledModule);
  const schemaNames = Object.keys(contract.schemas ?? {});
  const schemaEntries = schemaNames.map((typeName) => [
    typeName,
    schemaContractFor(compiledModule, typeName)
  ]);
  const schemaMap = new Map(schemaEntries);
  const toolContracts = Array.isArray(compiledModule?.__claspToolCallContracts)
    ? compiledModule.__claspToolCallContracts
    : [];
  const toolMap = new Map(toolContracts.map((tool) => [tool.name, createBamlToolShim(tool)]));
  const functionEntries = Object.entries(normalizeBamlFunctionDescriptors(options.functions));
  const functionMap = new Map(
    functionEntries.map(([name, descriptor]) => [
      name,
      createBamlFunctionShim(compiledModule, name, descriptor)
    ])
  );

  return Object.freeze({
    kind: "clasp-baml-shim",
    version: 1,
    contract,
    schemas: Object.freeze(Object.fromEntries(schemaEntries)),
    types: Object.freeze(Object.fromEntries(schemaEntries)),
    tools: Object.freeze(Object.fromEntries(toolMap)),
    functions: Object.freeze(Object.fromEntries(functionMap)),
    schema(typeName) {
      const schema = schemaMap.get(typeName);

      if (!schema) {
        throw new Error(`Unknown Clasp schema in BAML shim: ${String(typeName)}`);
      }

      return schema;
    },
    type(typeName) {
      return this.schema(typeName);
    },
    dynamicType(typeNames) {
      return createDynamicSchema(compiledModule, typeNames);
    },
    dynamicSchema(typeNames) {
      return this.dynamicType(typeNames);
    },
    tool(name) {
      const tool = toolMap.get(name);

      if (!tool) {
        throw new Error(`Unknown Clasp tool in BAML shim: ${String(name)}`);
      }

      return tool;
    },
    function(name) {
      const fn = functionMap.get(name);

      if (!fn) {
        throw new Error(`Unknown Clasp function in BAML shim: ${String(name)}`);
      }

      return fn;
    }
  });
}

function normalizeBamlFunctionDescriptors(functions) {
  if (!functions || typeof functions !== "object" || Array.isArray(functions)) {
    return {};
  }

  return functions;
}

function createBamlToolShim(tool) {
  return Object.freeze({
    kind: "clasp-baml-tool",
    version: 1,
    name: tool.name,
    operation: tool.operation,
    requestType: tool.requestType,
    responseType: tool.responseType,
    requestSchema: tool.requestSchema,
    responseSchema: tool.responseSchema,
    prepare(input, id = null, options = null) {
      return tool.prepare(input, id, options);
    },
    call(input, id = null, options = null) {
      return tool.prepare(input, id, options);
    },
    parse(payload, options = null) {
      return tool.evaluateResult(payload, options).result;
    },
    parseEnvelope(payload) {
      if (typeof payload === "string") {
        return tool.parseResultEnvelope(payload);
      }

      return tool.decodeResultEnvelope(payload);
    },
    stream(initial = null) {
      return tool.streamResult(initial);
    }
  });
}

function createBamlFunctionShim(compiledModule, name, descriptor) {
  const normalized = normalizeBamlFunctionDescriptor(name, descriptor);
  const inputSchema = normalized.input ? schemaContractFor(compiledModule, normalized.input) : null;
  const outputSchema = normalizeBamlOutputSchema(compiledModule, normalized.output);
  const execute =
    typeof normalized.execute === "function"
      ? (input) => normalized.execute(input, compiledModule)
      : resolveBamlExport(compiledModule, normalized.exportName);

  return Object.freeze({
    kind: "clasp-baml-function",
    version: 1,
    name,
    exportName: normalized.exportName,
    inputType: normalized.input ?? null,
    outputType: normalized.output ?? null,
    schema: outputSchema,
    call(input, path = "input") {
      const normalizedInput = inputSchema
        ? inputSchema.toHost(inputSchema.fromHost(input, path), path)
        : input;
      return decodeBamlOutput(outputSchema, execute(normalizedInput), "result");
    },
    invoke(input, path = "input") {
      return this.call(input, path);
    },
    parse(value, path = "result") {
      return decodeBamlOutput(outputSchema, value, path);
    },
    parseJson(jsonText, path = "result") {
      return decodeBamlJsonOutput(outputSchema, jsonText, path);
    }
  });
}

function normalizeBamlFunctionDescriptor(name, descriptor) {
  if (typeof descriptor === "string") {
    return { exportName: descriptor, input: null, output: null };
  }

  if (Array.isArray(descriptor)) {
    return { exportName: name, input: null, output: descriptor };
  }

  if (!descriptor || typeof descriptor !== "object") {
    return { exportName: name, input: null, output: null };
  }

  return {
    exportName: descriptor.export ?? descriptor.exportName ?? name,
    input: descriptor.input ?? null,
    output: descriptor.output ?? null,
    execute: descriptor.execute
  };
}

function normalizeBamlOutputSchema(compiledModule, output) {
  if (Array.isArray(output)) {
    return createDynamicSchema(compiledModule, output);
  }

  if (typeof output === "string" && output !== "") {
    return schemaContractFor(compiledModule, output);
  }

  return null;
}

function resolveBamlExport(compiledModule, exportName) {
  const exportValue = compiledModule?.[exportName];

  if (typeof exportValue !== "function") {
    throw new Error(`Missing Clasp export for BAML shim: ${String(exportName)}`);
  }

  return exportValue;
}

function decodeBamlOutput(schema, value, path) {
  if (!schema) {
    return value;
  }

  if (typeof value === "string") {
    return decodeBamlJsonOutput(schema, value, path);
  }

  if (schema.kind === "clasp-dynamic-schema") {
    return schema.select(value, path).value;
  }

  return schema.toHost(schema.fromHost(value, path), path);
}

function decodeBamlJsonOutput(schema, jsonText, path) {
  if (!schema) {
    return JSON.parse(jsonText);
  }

  if (schema.kind === "clasp-dynamic-schema") {
    return schema.selectJson(jsonText, path).value;
  }

  return schema.decodeJson(jsonText, path);
}

function normalizeDynamicSchemaTypeNames(typeNames) {
  if (!Array.isArray(typeNames) || typeNames.length === 0) {
    throw new Error("Dynamic schemas require a non-empty array of schema names.");
  }

  const normalized = [];
  const seen = new Set();

  for (const typeName of typeNames) {
    if (typeof typeName !== "string" || typeName === "") {
      throw new Error("Dynamic schemas require schema names to be non-empty strings.");
    }

    if (!seen.has(typeName)) {
      normalized.push(typeName);
      seen.add(typeName);
    }
  }

  return normalized;
}

function selectDynamicSchemaMatch(entries, value, path) {
  const matches = [];

  for (const [typeName, contract] of entries) {
    try {
      const matchedValue = contract.toHost(contract.fromHost(value, path), path);
      matches.push(
        Object.freeze({
          typeName,
          schema: contract,
          value: matchedValue
        })
      );
    } catch (_error) {
      // Try the remaining constrained schema candidates.
    }
  }

  return expectDynamicSchemaSelection(entries, matches, path);
}

function selectDynamicSchemaDecode(entries, jsonText, path) {
  const matches = [];

  for (const [typeName, contract] of entries) {
    try {
      matches.push(
        Object.freeze({
          typeName,
          schema: contract,
          value: contract.decodeJson(jsonText)
        })
      );
    } catch (_error) {
      // Try the remaining constrained schema candidates.
    }
  }

  return expectDynamicSchemaSelection(entries, matches, path);
}

function expectDynamicSchemaSelection(entries, matches, path) {
  if (matches.length === 1) {
    return matches[0];
  }

  const typeNames = entries.map(([typeName]) => typeName).join(", ");

  if (matches.length === 0) {
    throw new Error(`${path} did not match any dynamic schema candidate: ${typeNames}`);
  }

  throw new Error(
    `${path} matched multiple dynamic schema candidates: ${matches.map((match) => match.typeName).join(", ")}`
  );
}

function defaultProviderContract(compiledModule, hostBindings) {
  const bindings = (hostBindings ?? [])
    .map((binding) => defaultProviderBinding(compiledModule, binding))
    .filter((binding) => binding !== null);
  const providerMap = new Map();

  for (const binding of bindings) {
    const current =
      providerMap.get(binding.provider) ??
      {
        name: binding.provider,
        runtimeNames: [],
        bindingNames: []
      };

    current.runtimeNames.push(binding.runtimeName);
    current.bindingNames.push(binding.name);
    providerMap.set(binding.provider, current);
  }

  return Object.freeze({
    kind: "clasp-provider-contract",
    version: 1,
    providers: Object.freeze(
      Array.from(providerMap.values(), (provider) =>
        Object.freeze({
          name: provider.name,
          runtimeNames: Object.freeze(provider.runtimeNames),
          bindingNames: Object.freeze(provider.bindingNames)
        })
      )
    ),
    bindings: Object.freeze(bindings)
  });
}

function defaultProviderBinding(compiledModule, binding) {
  const descriptor = parseProviderRuntimeName(binding?.runtimeName);

  if (!descriptor) {
    return null;
  }

  return Object.freeze({
    name: binding?.name ?? descriptor.operation,
    runtimeName: binding?.runtimeName ?? `${descriptor.namespace}:${descriptor.operation}`,
    provider: descriptor.provider,
    namespace: descriptor.namespace,
    operation: descriptor.operation,
    capability: Object.freeze({
      id: `capability:provider:${descriptor.provider}:${descriptor.operation}`,
      kind: "model-runtime-operation",
      provider: descriptor.provider,
      operation: descriptor.operation,
      runtimeName: binding?.runtimeName ?? `${descriptor.namespace}:${descriptor.operation}`
    }),
    secretConsumer(boundary = null) {
      return createProviderSecretConsumerSurface(
        compiledModule,
        binding?.name ?? descriptor.operation,
        descriptor,
        boundary
      );
    },
    params: Object.freeze(binding?.params ?? []),
    returns: binding?.returns ?? null
  });
}

function parseProviderRuntimeName(runtimeName) {
  if (typeof runtimeName !== "string") {
    return null;
  }

  const parts = runtimeName.split(":");

  if (parts[0] !== "provider" || parts.length < 2) {
    return null;
  }

  if (parts.length === 2) {
    return {
      namespace: "provider",
      provider: "provider",
      operation: parts[1]
    };
  }

  return {
    namespace: parts[0],
    provider: parts[1],
    operation: parts.slice(2).join(":")
  };
}

export function providerContractFor(compiledModule) {
  return bindingContractFor(compiledModule).providers;
}

function defaultStorageContract(compiledModule, hostBindings) {
  const bindings = (hostBindings ?? [])
    .map((binding) => defaultStorageBinding(compiledModule, binding))
    .filter((binding) => binding !== null);
  const tableMap = new Map();

  for (const binding of bindings) {
    for (const table of binding.tables) {
      const key = `${table.schemaType}:${table.name}`;

      if (!tableMap.has(key)) {
        tableMap.set(key, table);
      }
    }
  }

  return Object.freeze({
    kind: "clasp-storage-contract",
    version: 1,
    bindings: Object.freeze(bindings),
    tables: Object.freeze(Array.from(tableMap.values()))
  });
}

function defaultStorageBinding(compiledModule, binding) {
  const descriptor = parseStorageRuntimeName(binding?.runtimeName);

  if (!descriptor) {
    return null;
  }

  const params = Object.freeze(
    (binding?.params ?? []).map((param) =>
      Object.freeze({
        ...param,
        storageType: describeStorageType(param?.type, param?.schema)
      })
    )
  );
  const returns =
    binding?.returns == null
      ? null
      : Object.freeze({
          ...binding.returns,
          storageType: describeStorageType(binding.returns?.type, binding.returns?.schema)
        });
  const tables = collectStorageTables([...params, ...(returns ? [returns] : [])]);

  return Object.freeze({
    name: binding?.name ?? descriptor.operation,
    runtimeName: binding?.runtimeName ?? `storage:${descriptor.operation}`,
    operation: descriptor.operation,
    capability: Object.freeze({
      id: `capability:storage:${descriptor.operation}`,
      kind: "storage-operation",
      runtimeName: binding?.runtimeName ?? `storage:${descriptor.operation}`
    }),
    params,
    returns,
    tables: Object.freeze(tables)
  });
}

function parseStorageRuntimeName(runtimeName) {
  if (typeof runtimeName !== "string") {
    return null;
  }

  const parts = runtimeName.split(":");

  if (parts[0] !== "storage" || parts.length < 2) {
    return null;
  }

  return {
    namespace: "storage",
    operation: parts.slice(1).join(":")
  };
}

function defaultSqliteContract(hostBindings) {
  const bindings = (hostBindings ?? [])
    .map(defaultSqliteBinding)
    .filter((binding) => binding !== null);

  return Object.freeze({
    kind: "clasp-sqlite-contract",
    version: 1,
    bindings: Object.freeze(bindings)
  });
}

function defaultSqliteBinding(binding) {
  const descriptor = parseSqliteRuntimeName(binding?.runtimeName);

  if (!descriptor) {
    return null;
  }

  const params = Object.freeze(
    (binding?.params ?? []).map((param) =>
      Object.freeze({
        ...param,
        storageType: describeStorageType(param?.type, param?.schema)
      })
    )
  );
  const returns =
    binding?.returns == null
      ? null
      : Object.freeze({
          ...binding.returns,
          storageType: describeStorageType(binding.returns?.type, binding.returns?.schema)
        });

  return Object.freeze({
    name: binding?.name ?? descriptor.operation,
    runtimeName: binding?.runtimeName ?? `sqlite:${descriptor.operation}`,
    operation: descriptor.operation,
    unsafe:
      descriptor.unsafe
        ? Object.freeze({
            kind: "clasp-sqlite-unsafe-sql",
            version: 1,
            baseOperation: descriptor.baseOperation,
            sqlParameterIndex: 1,
            rowContract: returns?.storageType ?? null,
            audit: Object.freeze({
              kind: "clasp-sqlite-unsafe-sql-audit-metadata",
              version: 1,
              bindingName: binding?.name ?? descriptor.operation,
              runtimeName: binding?.runtimeName ?? `sqlite:${descriptor.operation}`,
              operation: descriptor.operation,
              baseOperation: descriptor.baseOperation
            })
          })
        : null,
    transaction:
      descriptor.transaction === null
        ? null
        : Object.freeze({
            kind: "clasp-sqlite-transaction-boundary",
            version: 1,
            isolation: descriptor.transaction.isolation,
            boundary: descriptor.transaction.boundary
          }),
    mutation:
      descriptor.mutation === null
        ? null
        : Object.freeze({
            kind: "clasp-sqlite-mutation",
            version: 1,
            cardinality: descriptor.mutation.cardinality
          }),
    capability: Object.freeze({
      id: `capability:sqlite:${descriptor.operation}`,
      kind: "sqlite-connection-operation",
      runtimeName: binding?.runtimeName ?? `sqlite:${descriptor.operation}`
    }),
    params,
    returns
  });
}

function parseSqliteRuntimeName(runtimeName) {
  if (typeof runtimeName !== "string") {
    return null;
  }

  const parts = runtimeName.split(":");

  if (parts[0] !== "sqlite" || parts.length < 2) {
    return null;
  }

  const operation = parts[1];
  const baseOperation = sqliteBaseOperation(operation);
  const isolation = normalizeSqliteIsolationLevel(parts[2]);

  if (baseOperation === null) {
    return null;
  }

  return {
    namespace: "sqlite",
    operation,
    baseOperation,
    unsafe: operation !== baseOperation,
    transaction:
      baseOperation === "mutateOne" || baseOperation === "mutateAll"
        ? {
            isolation: isolation ?? "deferred",
            boundary: "binding"
          }
        : null,
    mutation:
      baseOperation === "mutateOne"
        ? { cardinality: "one" }
        : baseOperation === "mutateAll"
          ? { cardinality: "many" }
          : null
  };
}

function sqliteBaseOperation(operation) {
  switch (operation) {
    case "open":
    case "openReadonly":
    case "queryOne":
    case "queryAll":
    case "mutateOne":
    case "mutateAll":
      return operation;
    case "unsafeQueryOne":
      return "queryOne";
    case "unsafeQueryAll":
      return "queryAll";
    case "unsafeMutateOne":
      return "mutateOne";
    case "unsafeMutateAll":
      return "mutateAll";
    default:
      return null;
  }
}

export function sqliteContractFor(compiledModule) {
  return bindingContractFor(compiledModule).sqlite;
}

export function storageContractFor(compiledModule) {
  return bindingContractFor(compiledModule).storage;
}

export function createSqliteRuntime(compiledModule, options = {}) {
  if (!compiledModule || typeof compiledModule.__claspAdaptHostBindings !== "function") {
    throw new Error("createSqliteRuntime requires a generated Clasp module.");
  }

  const runtimeOptions = normalizeSqliteRuntimeOptions(options);
  const contract = sqliteContractFor(compiledModule);
  const bindingMap = new Map(contract.bindings.map((binding) => [binding.name, binding]));
  const runtimeBindingMap = new Map(
    contract.bindings.map((binding) => [binding.runtimeName, binding])
  );
  const liveConnections = new Map();
  const auditLog = [];
  const implementations = {};
  let nextConnectionId = 1;
  let nextAuditSequence = 1;

  const runtime = {
    contract,
    bindings: contract.bindings,
    binding(name) {
      const found = bindingMap.get(name) ?? runtimeBindingMap.get(name) ?? null;

      if (!found) {
        throw new Error(`Unknown Clasp sqlite binding: ${String(name)}`);
      }

      return found;
    },
    open(path, connectionOptions = {}) {
      return openSqliteConnection(path, {
        ...connectionOptions,
        readOnly: false
      });
    },
    openReadonly(path, connectionOptions = {}) {
      return openSqliteConnection(path, {
        ...connectionOptions,
        readOnly: true
      });
    },
    queryOne(connectionOrId, sql, ...parameters) {
      return executeSqliteQuery("queryOne", null, connectionOrId, sql, parameters);
    },
    queryAll(connectionOrId, sql, ...parameters) {
      return executeSqliteQuery("queryAll", null, connectionOrId, sql, parameters);
    },
    executeQuery(operation, binding, connectionOrId, sql, parameters) {
      return executeSqliteQuery(operation, binding, connectionOrId, sql, parameters);
    },
    mutateOne(connectionOrId, sql, ...parameters) {
      return executeSqliteMutation("mutateOne", null, connectionOrId, sql, parameters);
    },
    mutateAll(connectionOrId, sql, ...parameters) {
      return executeSqliteMutation("mutateAll", null, connectionOrId, sql, parameters);
    },
    executeMutation(operation, binding, connectionOrId, sql, parameters) {
      return executeSqliteMutation(operation, binding, connectionOrId, sql, parameters);
    },
    transaction(connectionOrId, options, action) {
      const transactionOptions = normalizeSqliteTransactionInvocation(options, action);
      return withSqliteTransaction(
        connectionOrId,
        transactionOptions.options,
        transactionOptions.action
      );
    },
    call(name, ...args) {
      const binding = this.binding(name);
      return invokeSqliteBinding(runtime, binding, args, runtimeOptions);
    },
    connection(connectionOrId) {
      return resolveSqliteConnection(connectionOrId).descriptor;
    },
    database(connectionOrId) {
      return resolveSqliteConnection(connectionOrId).database;
    },
    listConnections() {
      return Object.freeze(
        Array.from(liveConnections.values(), (entry) => entry.descriptor)
      );
    },
    auditEntries() {
      return Object.freeze([...auditLog]);
    },
    clearAuditEntries() {
      auditLog.length = 0;
    },
    close(connectionOrId) {
      const connection = resolveSqliteConnection(connectionOrId);
      connection.database.close();
      liveConnections.delete(connection.descriptor.id);
      return true;
    },
    install() {
      const runtimeBindings = {};
      for (const binding of contract.bindings) {
        if (!(binding.runtimeName in runtimeBindings)) {
          runtimeBindings[binding.runtimeName] = (...args) =>
            executeSqliteBinding(runtime, binding, args, runtimeOptions);
        }
      }
      installRuntime(runtimeBindings);
      return Object.freeze(runtimeBindings);
    }
  };

  for (const binding of contract.bindings) {
    const implementation = (...args) =>
      invokeSqliteBinding(runtime, binding, args, runtimeOptions);
    implementations[binding.name] = implementation;
    implementations[binding.runtimeName] = implementation;
  }

  runtime.implementations = Object.freeze(implementations);

  return Object.freeze(runtime);

  function openSqliteConnection(path, connectionOptions = {}) {
    const normalizedPath = normalizeSqliteConnectionPath(path);
    const readOnly = Boolean(connectionOptions.readOnly);
    const database = new DatabaseSync(normalizedPath, { open: true, readOnly });
    const descriptor = Object.freeze({
      id: `sqlite-connection-${nextConnectionId++}`,
      databasePath: normalizedPath,
      readOnly,
      memory: normalizedPath === ":memory:"
    });
    liveConnections.set(descriptor.id, {
      descriptor,
      database,
      transactionDepth: 0,
      nextSavepointId: 1
    });

    try {
      applySqliteSchemaHooks(descriptor, database, runtimeOptions.schema);

      if (typeof runtimeOptions.onOpen === "function") {
        runtimeOptions.onOpen({
          connection: descriptor,
          database
        });
      }
    } catch (error) {
      database.close();
      liveConnections.delete(descriptor.id);
      throw error;
    }

    return descriptor;
  }

  function applySqliteSchemaHooks(connection, database, schemaOptions) {
    if (!schemaOptions) {
      return;
    }

    let currentVersion = readSqliteUserVersion(database);
    const targetVersion = schemaOptions.version;
    const schemaContext = {
      connection,
      database,
      readOnly: connection.readOnly,
      targetVersion,
      readVersion() {
        return readSqliteUserVersion(database);
      },
      writeVersion(version) {
        if (connection.readOnly) {
          throw new Error("Cannot update SQLite schema version on a read-only connection.");
        }

        writeSqliteUserVersion(database, version);
        return readSqliteUserVersion(database);
      }
    };

    if (
      targetVersion !== null &&
      currentVersion !== targetVersion &&
      !connection.readOnly &&
      schemaOptions.migrate
    ) {
      schemaOptions.migrate({
        ...schemaContext,
        currentVersion,
        fromVersion: currentVersion,
        toVersion: targetVersion
      });
      currentVersion = readSqliteUserVersion(database);
    }

    if (schemaOptions.compatibility) {
      const compatibility = schemaOptions.compatibility({
        ...schemaContext,
        currentVersion,
        schemaVersion: currentVersion,
        expectedVersion: targetVersion
      });

      if (compatibility !== true && compatibility !== undefined) {
        const detail =
          typeof compatibility === "string"
            ? compatibility
            : `schema version ${currentVersion} is incompatible with expected version ${targetVersion}`;
        throw new Error(`Incompatible SQLite schema for ${connection.databasePath}: ${detail}`);
      }
    } else if (targetVersion !== null && currentVersion !== targetVersion) {
      throw new Error(
        `Incompatible SQLite schema for ${connection.databasePath}: expected version ${targetVersion} but found ${currentVersion}`
      );
    }
  }

  function readSqliteUserVersion(database) {
    const row = database.prepare("pragma user_version;").get();
    const version = row?.user_version;
    return Number.isInteger(version) && version >= 0 ? version : 0;
  }

  function writeSqliteUserVersion(database, version) {
    const normalizedVersion = normalizeSqliteSchemaVersion(version);
    database.exec(`pragma user_version = ${normalizedVersion};`);
  }

  function resolveSqliteConnection(connectionOrId) {
    const connectionId =
      typeof connectionOrId === "string"
        ? connectionOrId
        : connectionOrId?.id;

    if (typeof connectionId !== "string" || connectionId === "") {
      throw new Error("SQLite connection reference must include a non-empty id.");
    }

    const connection = liveConnections.get(connectionId);

    if (!connection) {
      throw new Error(`Unknown Clasp sqlite connection: ${connectionId}`);
    }

    return connection;
  }

  function withSqliteTransaction(connectionOrId, options, action) {
    if (typeof action !== "function") {
      throw new Error("SQLite transactions require an action function.");
    }

    const connection = resolveSqliteConnection(connectionOrId);
    const transactionOptions = normalizeSqliteTransactionOptions(options);
    const depth = connection.transactionDepth;
    const transactionId = `${connection.descriptor.id}:txn-${depth + 1}`;
    const savepointName =
      depth === 0 ? null : `clasp_txn_${connection.nextSavepointId++}`;

    if (depth === 0) {
      connection.database.exec(beginSqliteTransactionSql(transactionOptions.isolation));
    } else {
      connection.database.exec(`savepoint "${savepointName}";`);
    }

    connection.transactionDepth += 1;

    try {
      const descriptor = Object.freeze({
        kind: "clasp-sqlite-transaction",
        version: 1,
        id: transactionId,
        connection: connection.descriptor,
        isolation: transactionOptions.isolation,
        boundary: depth === 0 ? "connection" : "savepoint",
        depth: depth + 1,
        readOnly: connection.descriptor.readOnly
      });
      const result = action(descriptor);

      if (depth === 0) {
        connection.database.exec("commit;");
      } else {
        connection.database.exec(`release savepoint "${savepointName}";`);
      }

      return result;
    } catch (error) {
      if (depth === 0) {
        connection.database.exec("rollback;");
      } else {
        connection.database.exec(`rollback to savepoint "${savepointName}";`);
        connection.database.exec(`release savepoint "${savepointName}";`);
      }

      throw error;
    } finally {
      connection.transactionDepth = Math.max(connection.transactionDepth - 1, 0);
    }
  }

  function executeSqliteQuery(operation, binding, connectionOrId, sql, parameters) {
    const connection = resolveSqliteConnection(connectionOrId);
    const normalizedSql = normalizeSqliteQueryText(sql);
    const statement = connection.database.prepare(normalizedSql);
    const bindingArgs = parameters ?? [];
    recordUnsafeSqliteAudit(binding, connection, normalizedSql, bindingArgs);

    switch (operation) {
      case "queryOne":
        return statement.get(...bindingArgs);
      case "queryAll":
        return statement.all(...bindingArgs);
      default:
        throw new Error(`Unsupported Clasp sqlite query operation: ${operation}`);
    }
  }

  function executeSqliteMutation(operation, binding, connectionOrId, sql, parameters) {
    const transaction = binding?.transaction ?? null;
    return withSqliteTransaction(
      connectionOrId,
      {
        isolation: transaction?.isolation ?? "deferred"
      },
      () => {
        const connection = resolveSqliteConnection(connectionOrId);
        const normalizedSql = normalizeSqliteQueryText(sql);
        const statement = connection.database.prepare(normalizedSql);
        const bindingArgs = parameters ?? [];
        recordUnsafeSqliteAudit(binding, connection, normalizedSql, bindingArgs);

        switch (operation) {
          case "mutateOne":
            return statement.get(...bindingArgs);
          case "mutateAll":
            return statement.all(...bindingArgs);
          default:
            throw new Error(`Unsupported Clasp sqlite mutation operation: ${operation}`);
        }
      }
    );
  }

  function recordUnsafeSqliteAudit(binding, connection, sql, parameters) {
    if (!binding?.unsafe) {
      return;
    }

    auditLog.push(
      Object.freeze({
        kind: "clasp-sqlite-unsafe-sql-audit",
        version: 1,
        sequence: nextAuditSequence++,
        binding: Object.freeze({
          name: binding.name,
          runtimeName: binding.runtimeName,
          operation: binding.operation,
          baseOperation: binding.unsafe.baseOperation
        }),
        connection: connection.descriptor,
        sql,
        parameterCount: parameters.length,
        rowContract: binding.unsafe.rowContract,
        transaction: binding.transaction,
        mutation: binding.mutation,
        metadata: binding.unsafe.audit
      })
    );
  }
}

export function installSqliteRuntime(compiledModule, options = {}) {
  return createSqliteRuntime(compiledModule, options).install();
}

function normalizeSqliteRuntimeOptions(options) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    return {
      onOpen: null,
      schema: null
    };
  }

  return {
    onOpen: typeof options.onOpen === "function" ? options.onOpen : null,
    schema: normalizeSqliteSchemaOptions(options.schema)
  };
}

function normalizeSqliteSchemaOptions(schema) {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    return null;
  }

  const version = normalizeSqliteSchemaVersion(schema.version);
  const migrate = typeof schema.migrate === "function" ? schema.migrate : null;
  const compatibility =
    typeof schema.compatibility === "function" ? schema.compatibility : null;

  if (version === null && !migrate && !compatibility) {
    return null;
  }

  return Object.freeze({
    version,
    migrate,
    compatibility
  });
}

function normalizeSqliteSchemaVersion(version) {
  if (version === undefined || version === null) {
    return null;
  }

  if (!Number.isInteger(version) || version < 0) {
    throw new Error("SQLite schema version must be a non-negative integer.");
  }

  return version;
}

function normalizeSqliteConnectionPath(path) {
  if (typeof path !== "string") {
    throw new Error("SQLite connection path must be a string.");
  }

  const normalizedPath = path.trim();

  if (normalizedPath === "") {
    throw new Error("SQLite connection path cannot be empty.");
  }

  return normalizedPath;
}

function normalizeSqliteQueryText(sql) {
  if (typeof sql !== "string") {
    throw new Error("SQLite query text must be a string.");
  }

  const normalizedSql = sql.trim();

  if (normalizedSql === "") {
    throw new Error("SQLite query text cannot be empty.");
  }

  return normalizedSql;
}

function invokeSqliteBinding(runtime, binding, args, runtimeOptions) {
  const result = executeSqliteBinding(runtime, binding, args, runtimeOptions);
  const mappedResult = mapSqliteQueryResult(binding, result);
  if (mappedResult !== sqliteQueryResultUnmapped) {
    return mappedResult;
  }

  return result;
}

function describeStorageType(typeName, schema) {
  if (typeof typeName === "string" && typeName.startsWith("[") && typeName.endsWith("]")) {
    const itemType = typeName.slice(1, -1);
    const itemSchema = schema?.kind === "list" ? schema.item : null;
    return Object.freeze({
      kind: "list",
      semanticType: typeName,
      item: describeStorageType(itemType, itemSchema)
    });
  }

  const semanticType = typeof typeName === "string" && typeName !== ""
    ? typeName
    : storageSchemaTypeName(schema);

  switch (schema?.kind) {
    case "record":
      return Object.freeze({
        kind: "record",
        semanticType,
        schemaType: semanticType,
        tableName: storageTableName(semanticType)
      });
    case "enum":
      return Object.freeze({
        kind: "enum",
        semanticType,
        schemaType: semanticType,
        affinity: "TEXT"
      });
    case "int":
      return Object.freeze({
        kind: "primitive",
        semanticType: semanticType ?? "Int",
        affinity: "INTEGER"
      });
    case "str":
      return Object.freeze({
        kind: "primitive",
        semanticType: semanticType ?? "Str",
        affinity: "TEXT"
      });
    case "bool":
      return Object.freeze({
        kind: "primitive",
        semanticType: semanticType ?? "Bool",
        affinity: "INTEGER"
      });
    default:
      return semanticType === null
        ? null
        : Object.freeze({
            kind: "semantic",
            semanticType
          });
  }
}

function collectStorageTables(boundaries) {
  const tableMap = new Map();

  for (const boundary of boundaries) {
    collectStorageTablesFromType(boundary?.type, boundary?.schema, tableMap);
  }

  return Array.from(tableMap.values());
}

function collectStorageTablesFromType(typeName, schema, tableMap) {
  if (typeof typeName === "string" && typeName.startsWith("[") && typeName.endsWith("]")) {
    collectStorageTablesFromType(typeName.slice(1, -1), schema?.kind === "list" ? schema.item : null, tableMap);
    return;
  }

  if (schema?.kind !== "record") {
    return;
  }

  const schemaType = typeof typeName === "string" && typeName !== "" ? typeName : storageSchemaTypeName(schema);

  if (typeof schemaType !== "string" || schemaType === "") {
    return;
  }

  const key = `${schemaType}:${storageTableName(schemaType)}`;

  if (!tableMap.has(key)) {
    tableMap.set(key, createStorageTable(schemaType, schema));
  }
}

function createStorageTable(schemaType, schema) {
  const tableName = storageTableName(schemaType);
  const columns = Object.freeze(
    Object.entries(schema?.fields ?? {}).map(([name, field], index) =>
      createStorageColumn(name, field?.schema ?? null, field?.classification ?? "public", index)
    )
  );
  const declaration = `create table if not exists "${tableName}" (${columns.map((column) => column.declaration).join(", ")});`;

  return Object.freeze({
    name: tableName,
    schemaType,
    schema,
    columns,
    declaration
  });
}

function createStorageColumn(name, schema, classification, index) {
  const semanticType = storageSchemaTypeName(schema);
  const affinity = storageColumnAffinity(schema);
  const constraints = storageColumnConstraints(name, schema, index);
  const declaration = [
    `"${name}"`,
    affinity,
    ...constraints.map((constraint) => constraint.sql)
  ].join(" ");

  return Object.freeze({
    name,
    ordinal: index,
    semanticType,
    classification,
    affinity,
    constraints: Object.freeze(constraints),
    declaration
  });
}

function storageColumnAffinity(schema) {
  switch (schema?.kind) {
    case "int":
    case "bool":
      return "INTEGER";
    case "record":
    case "list":
      return "TEXT";
    case "enum":
    case "str":
    default:
      return "TEXT";
  }
}

function storageColumnConstraints(name, schema, index) {
  const constraints = [
    Object.freeze({
      kind: "not_null",
      sql: "NOT NULL"
    })
  ];

  if (index === 0 && name === "id") {
    constraints.push(
      Object.freeze({
        kind: "primary_key",
        sql: "PRIMARY KEY"
      })
    );
  }

  if (schema?.kind === "bool") {
    constraints.push(
      Object.freeze({
        kind: "boolean_domain",
        sql: `CHECK("${name}" IN (0, 1))`
      })
    );
  }

  if (schema?.kind === "record" || schema?.kind === "list") {
    constraints.push(
      Object.freeze({
        kind: "json_valid",
        sql: `CHECK(json_valid("${name}"))`
      })
    );
  }

  return constraints;
}

function storageSchemaTypeName(schema) {
  switch (schema?.kind) {
    case "record":
    case "enum":
    case "partial-record":
      return typeof schema.name === "string" && schema.name !== "" ? schema.name : null;
    case "list": {
      const itemType = storageSchemaTypeName(schema.item);
      return itemType === null ? null : `[${itemType}]`;
    }
    case "int":
      return "Int";
    case "str":
      return "Str";
    case "bool":
      return "Bool";
    default:
      return null;
  }
}

function storageTableName(typeName) {
  return String(typeName)
    .replace(/([a-z0-9])([A-Z])/g, "$1_$2")
    .replace(/[\[\]\s]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toLowerCase();
}

const sqliteQueryResultUnmapped = Symbol("clasp.sqlite.queryResultUnmapped");

function executeSqliteBinding(runtime, binding, args, runtimeOptions) {
  switch (binding.operation) {
    case "open":
      return runtime.open(args[0], runtimeOptions);
    case "openReadonly":
      return runtime.openReadonly(args[0], runtimeOptions);
    case "queryOne":
      return runtime.queryOne(args[0], args[1], ...args.slice(2));
    case "queryAll":
      return runtime.queryAll(args[0], args[1], ...args.slice(2));
    case "unsafeQueryOne":
      return runtime.executeQuery("queryOne", binding, args[0], args[1], args.slice(2));
    case "unsafeQueryAll":
      return runtime.executeQuery("queryAll", binding, args[0], args[1], args.slice(2));
    case "mutateOne":
      return runtime.executeMutation("mutateOne", binding, args[0], args[1], args.slice(2));
    case "mutateAll":
      return runtime.executeMutation("mutateAll", binding, args[0], args[1], args.slice(2));
    case "unsafeMutateOne":
      return runtime.executeMutation("mutateOne", binding, args[0], args[1], args.slice(2));
    case "unsafeMutateAll":
      return runtime.executeMutation("mutateAll", binding, args[0], args[1], args.slice(2));
    default:
      throw new Error(`Unsupported Clasp sqlite operation: ${binding.operation}`);
  }
}

function normalizeSqliteIsolationLevel(value) {
  if (value === undefined) {
    return null;
  }

  switch (value) {
    case "deferred":
    case "immediate":
    case "exclusive":
      return value;
    default:
      throw new Error(`Unsupported SQLite transaction isolation: ${String(value)}`);
  }
}

function normalizeSqliteTransactionInvocation(options, action) {
  if (typeof options === "function" && action === undefined) {
    return {
      options: {},
      action: options
    };
  }

  return {
    options: options ?? {},
    action
  };
}

function normalizeSqliteTransactionOptions(options) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    return Object.freeze({ isolation: "deferred" });
  }

  return Object.freeze({
    isolation: normalizeSqliteIsolationLevel(options.isolation) ?? "deferred"
  });
}

function beginSqliteTransactionSql(isolation) {
  switch (isolation) {
    case "immediate":
      return "begin immediate transaction;";
    case "exclusive":
      return "begin exclusive transaction;";
    case "deferred":
    default:
      return "begin deferred transaction;";
  }
}

function mapSqliteQueryResult(binding, result) {
  const returns = binding?.returns;
  const fromHost =
    returns && typeof returns.fromHost === "function" ? returns.fromHost : null;

  if (!fromHost) {
    return sqliteQueryResultUnmapped;
  }

  try {
    return fromHost(result, "result");
  } catch (_rawError) {
    const fallback = fallbackSqliteQueryResult(result);

    if (fallback === sqliteQueryResultUnmapped) {
      return sqliteQueryResultUnmapped;
    }

    return fromHost(fallback, "result");
  }
}

function fallbackSqliteQueryResult(result) {
  if (Array.isArray(result)) {
    let changed = false;
    const mapped = result.map((row) => {
      const fallback = fallbackSqliteQueryRow(row);
      if (fallback !== sqliteQueryResultUnmapped) {
        changed = true;
        return fallback;
      }
      return row;
    });
    return changed ? mapped : sqliteQueryResultUnmapped;
  }

  return fallbackSqliteQueryRow(result);
}

function fallbackSqliteQueryRow(row) {
  if (!row || typeof row !== "object" || Array.isArray(row)) {
    return sqliteQueryResultUnmapped;
  }

  const values = Object.values(row);
  return values.length === 1 ? values[0] : sqliteQueryResultUnmapped;
}

export function createProviderRuntime(compiledModule, options = {}) {
  if (!compiledModule || typeof compiledModule.__claspAdaptHostBindings !== "function") {
    throw new Error("createProviderRuntime requires a generated Clasp module.");
  }

  const runtimeOptions = normalizeProviderRuntimeOptions(options);
  const contract = providerContractFor(compiledModule);
  const bindingMap = new Map(contract.bindings.map((binding) => [binding.name, binding]));
  const runtimeBindingMap = new Map(
    contract.bindings.map((binding) => [binding.runtimeName, binding])
  );
  const implementations = {};

  for (const binding of contract.bindings) {
    const implementation = (...args) =>
      invokeProviderBinding(compiledModule, binding, args, runtimeOptions);
    implementations[binding.name] = implementation;
    implementations[binding.runtimeName] = implementation;
  }

  const runtime = {
    contract,
    providers: contract.providers,
    bindings: contract.bindings,
    implementations: Object.freeze(implementations),
    binding(name) {
      const found = bindingMap.get(name) ?? runtimeBindingMap.get(name) ?? null;

      if (!found) {
        throw new Error(`Unknown Clasp provider binding: ${String(name)}`);
      }

      return found;
    },
    call(name, ...args) {
      const binding = this.binding(name);
      return invokeProviderBinding(compiledModule, binding, args, runtimeOptions);
    },
    install() {
      const adaptedBindings =
        compiledModule.__claspAdaptHostBindings(this.implementations);
      installRuntime(adaptedBindings);
      return adaptedBindings;
    }
  };

  return Object.freeze(runtime);
}

export function installProviderRuntime(compiledModule, options = {}) {
  return createProviderRuntime(compiledModule, options).install();
}

function invokeProviderBinding(compiledModule, binding, args, runtimeOptions) {
  const provider = resolveProviderImplementation(binding, runtimeOptions.providers);
  const secretConsumer = binding.secretConsumer(
    resolveProviderSecretBoundary(binding, runtimeOptions)
  );
  const secretSource = resolveProviderSecretSource(compiledModule, runtimeOptions);
  return provider({
    id: `provider:${binding.provider}:${binding.operation}`,
    binding,
    provider: binding.provider,
    operation: binding.operation,
    args: Object.freeze(args.slice()),
    secretConsumer,
    secretHandles: secretConsumer.secretHandles,
    secretSource,
    resolveSecret(secretHandle, options = null) {
      return secretConsumer.resolve(secretHandle, secretSource, options);
    },
    resolveAllSecrets(options = null) {
      return secretConsumer.resolveAll(secretSource, options);
    }
  });
}

function resolveProviderImplementation(binding, providers) {
  const provider = providers?.[binding.provider];

  if (provider && typeof provider.invoke === "function") {
    return (request) => provider.invoke(request);
  }

  if (provider && typeof provider[binding.operation] === "function") {
    return (request) => provider[binding.operation](...request.args, request);
  }

  if (typeof provider === "function") {
    return (request) => provider(request);
  }

  throw new Error(
    `Missing Clasp provider implementation for ${binding.provider}:${binding.operation}`
  );
}

function normalizeProviderRuntimeOptions(options) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    return {
      providers: {},
      secrets: null,
      secretBoundary: null,
      secretBoundaryFor: null
    };
  }

  if (
    Object.prototype.hasOwnProperty.call(options, "providers") ||
    Object.prototype.hasOwnProperty.call(options, "secrets") ||
    Object.prototype.hasOwnProperty.call(options, "secretBoundary") ||
    Object.prototype.hasOwnProperty.call(options, "secretBoundaryFor")
  ) {
    return {
      providers: options.providers ?? {},
      secrets: options.secrets ?? null,
      secretEnvironment: options.secretEnvironment ?? null,
      secretProvider:
        options.secretProvider ?? options.hostSecretProvider ?? null,
      secretBoundary: options.secretBoundary ?? null,
      secretBoundaryFor:
        typeof options.secretBoundaryFor === "function"
          ? options.secretBoundaryFor
          : null
    };
  }

  return {
    providers: options,
    secrets: null,
    secretEnvironment: null,
    secretProvider: null,
    secretBoundary: null,
    secretBoundaryFor: null
  };
}

function resolveProviderSecretBoundary(binding, runtimeOptions) {
  if (typeof runtimeOptions.secretBoundaryFor === "function") {
    const resolved = runtimeOptions.secretBoundaryFor(binding);
    if (resolved !== undefined) {
      return resolved ?? null;
    }
  }

  return runtimeOptions.secretBoundary ?? null;
}

function resolveProviderSecretSource(compiledModule, runtimeOptions) {
  if (runtimeOptions.secrets !== null && runtimeOptions.secrets !== undefined) {
    return runtimeOptions.secrets;
  }

  if (
    runtimeOptions.secretEnvironment !== null &&
    runtimeOptions.secretEnvironment !== undefined &&
    compiledModule?.__claspSecretInjectors?.environment
  ) {
    return compiledModule.__claspSecretInjectors.environment(
      runtimeOptions.secretEnvironment,
      { label: "provider-runtime:environment" }
    );
  }

  if (
    runtimeOptions.secretProvider !== null &&
    runtimeOptions.secretProvider !== undefined &&
    compiledModule?.__claspSecretInjectors?.provider
  ) {
    return compiledModule.__claspSecretInjectors.provider(
      runtimeOptions.secretProvider,
      { label: "provider-runtime:provider" }
    );
  }

  return null;
}

function createProviderSecretConsumerSurface(
  compiledModule,
  bindingName,
  descriptor,
  boundary = null
) {
  const createSecretConsumer = compiledModule?.__claspCreateSecretConsumerSurface;

  if (typeof createSecretConsumer !== "function") {
    throw new Error(
      "Generated Clasp module does not expose secret-consumer helpers."
    );
  }

  return createSecretConsumer({
    kind: "provider",
    name: bindingName,
    id: `provider:${descriptor.provider}:${descriptor.operation}`,
    boundary,
    secretNames: Array.isArray(boundary?.secretNames) ? boundary.secretNames : []
  });
}

function defaultNativeInterop(hostBindings) {
  return Object.freeze({
    version: 1,
    abi: "clasp-native-v1",
    supportedTargets: Object.freeze(["bun", "worker", "react-native", "expo"]),
    bindings: Object.freeze((hostBindings ?? []).map(defaultNativeInteropBinding))
  });
}

function defaultNativeInteropBinding(binding) {
  const bindingKey = nativeInteropKey(binding?.name ?? binding?.runtimeName ?? "binding");
  const crateName = `clasp_${bindingKey}`;
  const nativeRoot = `native/${bindingKey}`;
  const cargoManifest = `${nativeRoot}/Cargo.toml`;

  return Object.freeze({
    name: binding?.name ?? bindingKey,
    runtimeName: binding?.runtimeName ?? binding?.name ?? bindingKey,
    capability: Object.freeze({
      id: `capability:foreign:${binding?.name ?? bindingKey}`,
      kind: "foreign-function",
      runtimeName: binding?.runtimeName ?? binding?.name ?? bindingKey
    }),
    generatedBinding: Object.freeze({
      module: `generated/native/${bindingKey}.mjs`,
      export: binding?.name ?? bindingKey
    }),
    rustCrate: Object.freeze({
      crateName,
      manifestPath: cargoManifest,
      libName: crateName,
      entrySymbol: binding?.runtimeName ?? binding?.name ?? bindingKey
    }),
    nativeLibrary: Object.freeze({
      baseName: crateName,
      headerPath: `${nativeRoot}/include/${crateName}.h`,
      entrySymbol: binding?.runtimeName ?? binding?.name ?? bindingKey
    }),
    targets: Object.freeze({
      bun: Object.freeze({
        runtime: "bun",
        loader: "bun:ffi",
        crateType: "cdylib",
        manifestPath: cargoManifest
      }),
      worker: Object.freeze({
        runtime: "bun",
        loader: "bun:ffi",
        crateType: "cdylib",
        manifestPath: cargoManifest
      }),
      reactNative: Object.freeze({
        runtime: "react-native",
        loader: "turbo-module",
        crateType: "staticlib",
        manifestPath: cargoManifest
      }),
      expo: Object.freeze({
        runtime: "expo",
        loader: "expo-module",
        crateType: "staticlib",
        manifestPath: cargoManifest
      })
    })
  });
}

function nativeInteropKey(name) {
  const key = String(name)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "");

  return key === "" ? "binding" : key;
}

export function nativeInteropContractFor(compiledModule) {
  return bindingContractFor(compiledModule).nativeInterop;
}

export function resolveNativeInteropPlan(compiledModule, options = {}) {
  const contract = nativeInteropContractFor(compiledModule);
  const target = normalizeNativeInteropTarget(options.target);
  const targetTriple =
    typeof options.targetTriple === "string" && options.targetTriple !== ""
      ? options.targetTriple
      : null;
  const release = options.release !== false;
  const bindingOverrides =
    options.bindings && typeof options.bindings === "object" ? options.bindings : {};
  const bindings = (contract.bindings ?? []).map((binding) => {
    const targetConfig = binding.targets?.[target.key];

    if (!targetConfig) {
      throw new Error(`Native interop target ${target.name} is not declared for ${binding.name}.`);
    }

    const override =
      bindingOverrides[binding.name] ??
      bindingOverrides[binding.runtimeName] ??
      {};
    const manifestPath =
      override.manifestPath ??
      override.cargoManifest ??
      targetConfig.manifestPath ??
      binding.rustCrate?.manifestPath ??
      null;
    const crateName = override.crateName ?? binding.rustCrate?.crateName ?? binding.name;
    const libName =
      override.libName ??
      override.baseName ??
      binding.nativeLibrary?.baseName ??
      binding.rustCrate?.libName ??
      crateName;
    const cargoCommand = [
      "cargo",
      "build",
      "--manifest-path",
      manifestPath
    ];

    if (release) {
      cargoCommand.push("--release");
    }

    if (targetTriple) {
      cargoCommand.push("--target", targetTriple);
    }

    return Object.freeze({
      name: binding.name,
      runtimeName: binding.runtimeName,
      capabilityId: binding.capability?.id ?? null,
      crateName,
      manifestPath,
      libName,
      generatedBinding: binding.generatedBinding ?? null,
      loader: targetConfig.loader,
      crateType: targetConfig.crateType,
      runtime: targetConfig.runtime,
      target: target.name,
      targetTriple,
      artifactFileName: nativeArtifactFileName(targetConfig.crateType, libName, targetTriple),
      capabilities: normalizeCapabilities(binding, override.capabilities),
      cargo: Object.freeze({
        command: cargoCommand,
        release,
        targetTriple
      })
    });
  });

  return Object.freeze({
    kind: "clasp-native-build-plan",
    version: 1,
    abi: contract.abi ?? "clasp-native-v1",
    target: target.name,
    targetTriple,
    release,
    bindings
  });
}

function normalizeNativeInteropTarget(target) {
  switch (target) {
    case undefined:
    case null:
    case "bun":
    case "server":
      return { key: "bun", name: "bun" };
    case "worker":
    case "bun-worker":
      return { key: "worker", name: "worker" };
    case "react-native":
    case "reactNative":
      return { key: "reactNative", name: "react-native" };
    case "expo":
      return { key: "expo", name: "expo" };
    default:
      throw new Error(`Unsupported Clasp native interop target: ${String(target)}`);
  }
}

function nativeArtifactFileName(crateType, libName, targetTriple) {
  if (crateType === "staticlib") {
    return `lib${libName}.a`;
  }

  const triple = targetTriple ?? "";

  if (triple.includes("windows")) {
    return `${libName}.dll`;
  }

  if (triple.includes("apple") || triple.includes("darwin")) {
    return `lib${libName}.dylib`;
  }

  return `lib${libName}.so`;
}

function normalizeCapabilities(binding, capabilitiesOverride) {
  if (Array.isArray(capabilitiesOverride) && capabilitiesOverride.length > 0) {
    return capabilitiesOverride.slice();
  }

  return binding.capability?.id ? [binding.capability.id] : [];
}

function defaultPlatformBridges() {
  return Object.freeze({
    react: Object.freeze({
      module: "runtime/bun/react.mjs",
      entry: "createReactInterop"
    }),
    reactNative: Object.freeze({
      module: "runtime/bun/react.mjs",
      entry: "createReactNativeBridge"
    }),
    expo: Object.freeze({
      module: "runtime/bun/react.mjs",
      entry: "createExpoBridge"
    })
  });
}

export function installCompiledModule(compiledModule, implementations = {}) {
  if (!compiledModule || typeof compiledModule.__claspAdaptHostBindings !== "function") {
    throw new Error("installCompiledModule requires a generated Clasp module.");
  }

  const packageBindings =
    typeof compiledModule.__claspPackageHostBindings === "function"
      ? compiledModule.__claspPackageHostBindings()
      : {};
  const runtimeBindings = {
    ...packageBindings,
    ...compiledModule.__claspAdaptHostBindings(implementations)
  };
  installRuntime(runtimeBindings);
  return runtimeBindings;
}

export async function requestPayloadJson(route, request) {
  const url = new URL(request.url);

  if (request.method === "GET") {
    return JSON.stringify(
      coerceRequestObject(readSearchParams(url.searchParams), route.requestSchema)
    );
  }

  const contentType = request.headers.get("content-type") ?? "";

  if (contentType.includes("application/json")) {
    const rawBody = (await request.text()).trim();
    return rawBody === "" ? "{}" : rawBody;
  }

  if (contentType.includes("application/x-www-form-urlencoded")) {
    const rawBody = await request.text();
    return JSON.stringify(
      coerceRequestObject(
        readSearchParams(new URLSearchParams(rawBody)),
        route.requestSchema
      )
    );
  }

  const rawBody = (await request.text()).trim();
  return rawBody === "" ? "{}" : rawBody;
}

export function serveCompiledModule(compiledModule, options = {}) {
  if (typeof Bun === "undefined" || typeof Bun.serve !== "function") {
    throw new Error("serveCompiledModule requires Bun.");
  }

  const contract = bindingContractFor(compiledModule);
  const routes = contract.routes;
  const port = options.port ?? 3001;

  return Bun.serve({
    port,
    async fetch(request) {
      const url = new URL(request.url);
      const assetResponse = await responseForAssetRequest(compiledModule, url.pathname, options);

      if (assetResponse) {
        return assetResponse;
      }

      const route = routes.find(
        (candidate) =>
          candidate.method === request.method && candidate.path === url.pathname
      );

      if (!route) {
        return jsonResponse(404, { error: "not_found", path: url.pathname });
      }

      let payload;
      try {
        payload = route.decodeRequest(await requestPayloadJson(route, request));
      } catch (error) {
        return errorResponse(route, 400, "invalid_request", error);
      }

      let result;
      try {
        result = await route.handler(payload);
      } catch (error) {
        return errorResponse(route, 502, "handler_failed", error);
      }

      try {
        return responseForRouteResult(route, result);
      } catch (error) {
        return errorResponse(route, 500, "invalid_response", error);
      }
    }
  });
}

export async function responseForAssetRequest(compiledModule, pathname, options = {}) {
  const contract = bindingContractFor(compiledModule);
  const generatedAsset = generatedAssetForPath(contract, pathname);

  if (generatedAsset) {
    return new Response(generatedAsset.content ?? "", {
      status: 200,
      headers: {
        "content-type": generatedAsset.contentType ?? "text/plain; charset=utf-8"
      }
    });
  }

  if (typeof Bun === "undefined" || typeof Bun.file !== "function") {
    return null;
  }

  const staticAsset = await staticAssetResponse(pathname, contract, options);
  return staticAsset;
}

export function responseForRouteResult(route, result) {
  if (route?.responseKind === "redirect") {
    const redirect = route.encodeResponse(result);
    return redirectResponse(redirect.status ?? 303, redirect.location);
  }

  return new Response(route.encodeResponse(result), {
    status: 200,
    headers: {
      "content-type":
        route?.responseKind === "page"
          ? "text/html; charset=utf-8"
          : "application/json"
    }
  });
}

function jsonResponse(status, payload) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "content-type": "application/json"
    }
  });
}

function textResponse(status, body) {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/plain; charset=utf-8"
    }
  });
}

function redirectResponse(status, location) {
  return new Response("", {
    status,
    headers: {
      location
    }
  });
}

function errorResponse(route, status, code, error) {
  const message = errorMessage(error);

  if (route?.responseKind === "page") {
    return textResponse(status, message);
  }

  return jsonResponse(status, {
    error: code,
    message
  });
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

function generatedAssetForPath(contract, pathname) {
  const assets = contract.staticAssets ?? [];

  return assets.find(
    (asset) => typeof asset?.href === "string" && asset.href === pathname
  ) ?? null;
}

async function staticAssetResponse(pathname, contract, options) {
  const assetBasePath =
    options.assetBasePath ??
    contract.staticAssetStrategy?.assetBasePath ??
    "/assets";
  const staticAssetsDir = options.staticAssetsDir;

  if (typeof staticAssetsDir !== "string" || staticAssetsDir === "") {
    return null;
  }

  const normalizedBasePath = assetBasePath.endsWith("/")
    ? assetBasePath
    : `${assetBasePath}/`;

  if (!pathname.startsWith(normalizedBasePath)) {
    return null;
  }

  const relativePath = pathname.slice(normalizedBasePath.length);

  if (relativePath === "" || relativePath.includes("..")) {
    return null;
  }

  const file = Bun.file(`${staticAssetsDir}/${relativePath}`);

  if (!(await file.exists())) {
    return null;
  }

  return new Response(file);
}

function readSearchParams(searchParams) {
  const entries = {};

  for (const [key, value] of searchParams.entries()) {
    entries[key] = value;
  }

  return entries;
}

function coerceRequestObject(rawValue, schema) {
  if (!schema || schema.kind !== "record") {
    return rawValue;
  }

  const value = isPlainObject(rawValue) ? rawValue : {};
  const coerced = {};

  for (const [fieldName, fieldSchema] of Object.entries(schema.fields ?? {})) {
    if (Object.prototype.hasOwnProperty.call(value, fieldName)) {
      coerced[fieldName] = coerceRequestValue(value[fieldName], unwrapFieldSchema(fieldSchema));
    }
  }

  for (const [fieldName, fieldValue] of Object.entries(value)) {
    if (!Object.prototype.hasOwnProperty.call(coerced, fieldName)) {
      coerced[fieldName] = fieldValue;
    }
  }

  return coerced;
}

function coerceRequestValue(rawValue, schema) {
  if (!schema) {
    return rawValue;
  }

  switch (schema.kind) {
    case "int":
      return maybeParseInt(rawValue);
    case "bool":
      return maybeParseBool(rawValue);
    case "str":
    case "enum":
      return rawValue;
    case "record":
      return coerceRequestObject(rawValue, schema);
    default:
      return rawValue;
  }
}

function unwrapFieldSchema(schema) {
  if (!schema || typeof schema !== "object" || Array.isArray(schema)) {
    return schema;
  }

  return schema.schema ?? schema;
}

function maybeParseInt(rawValue) {
  if (typeof rawValue !== "string" || !/^-?(0|[1-9]\d*)$/.test(rawValue)) {
    return rawValue;
  }

  return Number.parseInt(rawValue, 10);
}

function maybeParseBool(rawValue) {
  if (rawValue === "true") {
    return true;
  }

  if (rawValue === "false") {
    return false;
  }

  return rawValue;
}

function isPlainObject(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
