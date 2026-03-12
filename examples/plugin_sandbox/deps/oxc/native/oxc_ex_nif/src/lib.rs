use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};

use oxc_allocator::Allocator;
use oxc_ast::ast::{ImportOrExportKind, Statement};
use oxc_codegen::{Codegen, CodegenOptions, CodegenReturn};
use oxc_minifier::{CompressOptions, MangleOptions, Minifier, MinifierOptions};
use oxc_parser::{ParseOptions, Parser};
use oxc_semantic::SemanticBuilder;
use oxc_span::SourceType;
use oxc_transformer::{EnvOptions, JsxRuntime, TransformOptions, Transformer};
use oxc_transformer_plugins::{ReplaceGlobalDefines, ReplaceGlobalDefinesConfig};
use rustler::{Encoder, Env, NifResult, Term};
use serde_json::Value;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        message,
        code,
        sourcemap,
    }
}

fn json_to_term<'a>(env: Env<'a>, value: &Value) -> Term<'a> {
    match value {
        Value::Null => rustler::types::atom::nil().encode(env),
        Value::Bool(b) => b.encode(env),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.encode(env)
            } else if let Some(f) = n.as_f64() {
                f.encode(env)
            } else {
                rustler::types::atom::nil().encode(env)
            }
        }
        Value::String(s) => s.as_str().encode(env),
        Value::Array(arr) => {
            let terms: Vec<Term<'a>> = arr.iter().map(|v| json_to_term(env, v)).collect();
            terms.encode(env)
        }
        Value::Object(map) => {
            let keys: Vec<Term<'a>> = map
                .keys()
                .map(|k| {
                    rustler::types::atom::Atom::from_str(env, k)
                        .unwrap()
                        .encode(env)
                })
                .collect();
            let vals: Vec<Term<'a>> = map.values().map(|v| json_to_term(env, v)).collect();
            Term::map_from_arrays(env, &keys, &vals).unwrap()
        }
    }
}

fn format_errors(errors: &[oxc_diagnostics::OxcDiagnostic]) -> Vec<String> {
    errors.iter().map(ToString::to_string).collect()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn parse<'a>(env: Env<'a>, source: &str, filename: &str) -> NifResult<Term<'a>> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(filename).unwrap_or_default();
    let ret = Parser::new(&allocator, source, source_type)
        .with_options(ParseOptions {
            parse_regular_expression: true,
            ..ParseOptions::default()
        })
        .parse();

    if !ret.errors.is_empty() {
        let errors: Vec<Term<'a>> = ret
            .errors
            .iter()
            .map(|e| {
                let msg = e.to_string();
                Term::map_from_arrays(env, &[atoms::message().encode(env)], &[msg.encode(env)])
                    .unwrap()
            })
            .collect();
        return Ok((atoms::error(), errors).encode(env));
    }

    let json_str = ret.program.to_estree_ts_json(false);
    let json: Value = serde_json::from_str(&json_str).unwrap();
    let term = json_to_term(env, &json);

    Ok((atoms::ok(), term).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn valid(source: &str, filename: &str) -> bool {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(filename).unwrap_or_default();
    let ret = Parser::new(&allocator, source, source_type).parse();
    ret.errors.is_empty()
}

fn build_transform_options(
    jsx_runtime: &str,
    jsx_factory: &str,
    jsx_fragment: &str,
    import_source: &str,
    target: &str,
) -> TransformOptions {
    let mut options = TransformOptions::default();
    options.jsx.runtime = match jsx_runtime {
        "classic" => JsxRuntime::Classic,
        _ => JsxRuntime::Automatic,
    };
    if !jsx_factory.is_empty() {
        options.jsx.pragma = Some(jsx_factory.to_string());
    }
    if !jsx_fragment.is_empty() {
        options.jsx.pragma_frag = Some(jsx_fragment.to_string());
    }
    if !import_source.is_empty() {
        options.jsx.import_source = Some(import_source.to_string());
    }
    if !target.is_empty() {
        if let Ok(env) = EnvOptions::from_target(target) {
            options.env = env;
        }
    }
    options
}

#[rustler::nif(schedule = "DirtyCpu")]
#[allow(clippy::too_many_arguments)]
fn transform<'a>(
    env: Env<'a>,
    source: &str,
    filename: &str,
    jsx_runtime: &str,
    jsx_factory: &str,
    jsx_fragment: &str,
    import_source: &str,
    target: &str,
    sourcemap: bool,
) -> NifResult<Term<'a>> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(filename).unwrap_or_default();
    let path = Path::new(filename);

    let ret = Parser::new(&allocator, source, source_type)
        .with_options(ParseOptions {
            parse_regular_expression: true,
            ..ParseOptions::default()
        })
        .parse();

    if !ret.errors.is_empty() {
        let msgs = format_errors(&ret.errors);
        return Ok((atoms::error(), msgs).encode(env));
    }

    let mut program = ret.program;
    let scoping = SemanticBuilder::new()
        .build(&program)
        .semantic
        .into_scoping();

    let options = build_transform_options(
        jsx_runtime,
        jsx_factory,
        jsx_fragment,
        import_source,
        target,
    );

    let result =
        Transformer::new(&allocator, path, &options).build_with_scoping(scoping, &mut program);

    if !result.errors.is_empty() {
        let msgs = format_errors(&result.errors);
        return Ok((atoms::error(), msgs).encode(env));
    }

    if sourcemap {
        let codegen_opts = CodegenOptions {
            source_map_path: Some(PathBuf::from(filename)),
            ..Default::default()
        };
        let CodegenReturn { code, map, .. } =
            Codegen::new().with_options(codegen_opts).build(&program);
        if let Some(map) = map {
            let map_json = map.to_json_string();
            let result = Term::map_from_arrays(
                env,
                &[atoms::code().encode(env), atoms::sourcemap().encode(env)],
                &[code.encode(env), map_json.encode(env)],
            )
            .unwrap();
            Ok((atoms::ok(), result).encode(env))
        } else {
            Ok((atoms::ok(), code).encode(env))
        }
    } else {
        let CodegenReturn { code, .. } = Codegen::new().build(&program);
        Ok((atoms::ok(), code).encode(env))
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn minify<'a>(env: Env<'a>, source: &str, filename: &str, mangle: bool) -> NifResult<Term<'a>> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(filename).unwrap_or_default();

    let ret = Parser::new(&allocator, source, source_type)
        .with_options(ParseOptions {
            parse_regular_expression: true,
            ..ParseOptions::default()
        })
        .parse();

    if !ret.errors.is_empty() {
        let msgs = format_errors(&ret.errors);
        return Ok((atoms::error(), msgs).encode(env));
    }

    let mut program = ret.program;

    let options = MinifierOptions {
        mangle: mangle.then(MangleOptions::default),
        compress: Some(CompressOptions::default()),
    };
    let min_ret = Minifier::new(options).minify(&allocator, &mut program);

    let CodegenReturn { code, .. } = Codegen::new()
        .with_options(CodegenOptions::minify())
        .with_scoping(min_ret.scoping)
        .build(&program);

    Ok((atoms::ok(), code).encode(env))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn imports<'a>(env: Env<'a>, source: &str, filename: &str) -> NifResult<Term<'a>> {
    let allocator = Allocator::default();
    let source_type = SourceType::from_path(filename).unwrap_or_default();
    let ret = Parser::new(&allocator, source, source_type)
        .with_options(ParseOptions {
            parse_regular_expression: true,
            ..ParseOptions::default()
        })
        .parse();

    if !ret.errors.is_empty() {
        let msgs = format_errors(&ret.errors);
        return Ok((atoms::error(), msgs).encode(env));
    }

    let mut specifiers = Vec::new();
    for stmt in ret.program.body.iter() {
        if let Statement::ImportDeclaration(decl) = stmt {
            if decl.import_kind != ImportOrExportKind::Type {
                specifiers.push(decl.source.value.to_string());
            }
        }
    }

    Ok((atoms::ok(), specifiers).encode(env))
}

/// Normalize a module specifier like `"./foo"` or `"./foo.ts"` to a key like `"foo"`.
fn normalize_specifier(specifier: &str) -> String {
    let s = specifier.strip_prefix("./").unwrap_or(specifier);
    s.strip_suffix(".ts")
        .or_else(|| s.strip_suffix(".tsx"))
        .or_else(|| s.strip_suffix(".js"))
        .or_else(|| s.strip_suffix(".jsx"))
        .unwrap_or(s)
        .to_string()
}

/// Transform a single TS/JS module, strip import/export syntax, return JS + list of import sources.
fn transform_module(
    allocator: &Allocator,
    source: &str,
    filename: &str,
    transform_options: &TransformOptions,
) -> Result<(String, Vec<String>), Vec<String>> {
    let source_type = SourceType::from_path(filename).unwrap_or_default();
    let path = Path::new(filename);

    let ret = Parser::new(allocator, source, source_type)
        .with_options(ParseOptions {
            parse_regular_expression: true,
            ..ParseOptions::default()
        })
        .parse();

    if !ret.errors.is_empty() {
        return Err(format_errors(&ret.errors));
    }

    let mut program = ret.program;

    // Collect import sources before transform (which removes type-only imports).
    // Skip `import type { ... }` — they don't create runtime dependencies.
    let mut imports = Vec::new();
    for stmt in program.body.iter() {
        if let Statement::ImportDeclaration(decl) = stmt {
            if decl.import_kind != ImportOrExportKind::Type {
                imports.push(decl.source.value.to_string());
            }
        }
    }

    let scoping = SemanticBuilder::new()
        .build(&program)
        .semantic
        .into_scoping();

    let result = Transformer::new(allocator, path, transform_options)
        .build_with_scoping(scoping, &mut program);

    if !result.errors.is_empty() {
        return Err(format_errors(&result.errors));
    }

    // Strip module syntax: remove imports, unwrap exports
    let mut aliases: Vec<(String, String)> = Vec::new();
    let mut new_body = oxc_allocator::Vec::new_in(allocator);
    for stmt in program.body.into_iter() {
        match stmt {
            // Drop all import declarations
            Statement::ImportDeclaration(_) => {}
            // Drop re-export-all: `export * from './foo'`
            Statement::ExportAllDeclaration(_) => {}
            // `export class Foo {}` / `export const x = ...` → keep the declaration
            Statement::ExportNamedDeclaration(decl) => {
                let inner = decl.unbox();
                if let Some(declaration) = inner.declaration {
                    new_body.push(Statement::from(declaration));
                }
                // `export { local as exported }` without declaration — emit alias if renamed
                for spec in inner.specifiers.iter() {
                    let local = spec.local.name().as_str();
                    let exported = spec.exported.name().as_str();
                    if local != exported {
                        aliases.push((local.to_string(), exported.to_string()));
                    }
                }
            }
            // `export default expr` → keep as expression statement
            Statement::ExportDefaultDeclaration(decl) => {
                let inner = decl.unbox();
                match inner.declaration {
                    oxc_ast::ast::ExportDefaultDeclarationKind::FunctionDeclaration(f) => {
                        new_body.push(Statement::FunctionDeclaration(f));
                    }
                    oxc_ast::ast::ExportDefaultDeclarationKind::ClassDeclaration(c) => {
                        new_body.push(Statement::ClassDeclaration(c));
                    }
                    oxc_ast::ast::ExportDefaultDeclarationKind::TSInterfaceDeclaration(_) => {}
                    _ => {}
                }
            }
            // Keep everything else as-is
            other => new_body.push(other),
        }
    }
    program.body = new_body;

    let CodegenReturn { code, .. } = Codegen::new().build(&program);

    // Append alias declarations for renamed exports: `export { fetchImpl as fetch }`
    let mut result = code;
    for (local, exported) in &aliases {
        result.push_str(&format!("var {exported} = {local};\n"));
    }

    Ok((result, imports))
}

/// Topologically sort modules by their import dependencies (Kahn's algorithm).
fn topo_sort(modules: &HashMap<String, Vec<String>>) -> Result<Vec<String>, String> {
    let all_keys: HashSet<&String> = modules.keys().collect();

    // Build adjacency: dep → dependents (for Kahn's)
    let mut in_degree: HashMap<&String, usize> = HashMap::new();
    let mut dependents: HashMap<&String, Vec<&String>> = HashMap::new();

    for key in &all_keys {
        in_degree.insert(key, 0);
    }

    for (key, deps) in modules {
        for dep_raw in deps {
            let dep_key = normalize_specifier(dep_raw);
            if let Some(dep_ref) = all_keys.iter().find(|k| ***k == dep_key) {
                *in_degree.entry(key).or_insert(0) += 1;
                dependents.entry(dep_ref).or_default().push(key);
            }
        }
    }

    let mut queue: VecDeque<&String> = in_degree
        .iter()
        .filter(|(_, &deg)| deg == 0)
        .map(|(&k, _)| k)
        .collect();

    let mut sorted = Vec::new();
    while let Some(node) = queue.pop_front() {
        sorted.push(node.clone());
        if let Some(deps) = dependents.get(node) {
            for dep in deps {
                if let Some(deg) = in_degree.get_mut(dep) {
                    *deg -= 1;
                    if *deg == 0 {
                        queue.push_back(dep);
                    }
                }
            }
        }
    }

    if sorted.len() != all_keys.len() {
        return Err("Circular dependency detected".to_string());
    }

    Ok(sorted)
}

/// Decoded bundle options from Elixir keyword list.
struct BundleOptions {
    minify: bool,
    banner: Option<String>,
    footer: Option<String>,
    define: Vec<(String, String)>,
    sourcemap: bool,
    drop_console: bool,
    jsx_runtime: String,
    jsx_factory: String,
    jsx_fragment: String,
    import_source: String,
    target: String,
}

impl BundleOptions {
    fn from_term(env: Env<'_>, term: Term<'_>) -> Self {
        let mut opts = Self {
            minify: false,
            banner: None,
            footer: None,
            define: Vec::new(),
            sourcemap: false,
            drop_console: false,
            jsx_runtime: "automatic".to_string(),
            jsx_factory: String::new(),
            jsx_fragment: String::new(),
            import_source: String::new(),
            target: String::new(),
        };

        let minify_atom = rustler::types::atom::Atom::from_str(env, "minify").unwrap();
        let banner_atom = rustler::types::atom::Atom::from_str(env, "banner").unwrap();
        let footer_atom = rustler::types::atom::Atom::from_str(env, "footer").unwrap();
        let sourcemap_atom = rustler::types::atom::Atom::from_str(env, "sourcemap").unwrap();
        let drop_console_atom = rustler::types::atom::Atom::from_str(env, "drop_console").unwrap();
        let define_atom = rustler::types::atom::Atom::from_str(env, "define").unwrap();
        let jsx_atom = rustler::types::atom::Atom::from_str(env, "jsx").unwrap();
        let jsx_factory_atom = rustler::types::atom::Atom::from_str(env, "jsx_factory").unwrap();
        let jsx_fragment_atom = rustler::types::atom::Atom::from_str(env, "jsx_fragment").unwrap();
        let import_source_atom =
            rustler::types::atom::Atom::from_str(env, "import_source").unwrap();
        let target_atom = rustler::types::atom::Atom::from_str(env, "target").unwrap();

        if let Ok(list) = term.decode::<Vec<(rustler::Atom, Term<'_>)>>() {
            for (key, val) in list {
                if key == minify_atom {
                    opts.minify = val.decode::<bool>().unwrap_or(false);
                } else if key == banner_atom {
                    opts.banner = val.decode::<String>().ok();
                } else if key == footer_atom {
                    opts.footer = val.decode::<String>().ok();
                } else if key == sourcemap_atom {
                    opts.sourcemap = val.decode::<bool>().unwrap_or(false);
                } else if key == drop_console_atom {
                    opts.drop_console = val.decode::<bool>().unwrap_or(false);
                } else if key == jsx_atom {
                    let classic = rustler::types::atom::Atom::from_str(env, "classic").unwrap();
                    if let Ok(atom) = val.decode::<rustler::Atom>() {
                        if atom == classic {
                            opts.jsx_runtime = "classic".to_string();
                        }
                    }
                } else if key == jsx_factory_atom {
                    opts.jsx_factory = val.decode::<String>().unwrap_or_default();
                } else if key == jsx_fragment_atom {
                    opts.jsx_fragment = val.decode::<String>().unwrap_or_default();
                } else if key == define_atom {
                    if let Ok(map) = val.decode::<HashMap<String, String>>() {
                        opts.define = map.into_iter().collect();
                    }
                } else if key == import_source_atom {
                    opts.import_source = val.decode::<String>().unwrap_or_default();
                } else if key == target_atom {
                    opts.target = val.decode::<String>().unwrap_or_default();
                }
            }
        }

        opts
    }
}

#[rustler::nif(schedule = "DirtyCpu")]
fn bundle<'a>(
    env: Env<'a>,
    files: Vec<(String, String)>,
    opts_term: Term<'a>,
) -> NifResult<Term<'a>> {
    let opts = BundleOptions::from_term(env, opts_term);

    // Build a map of normalized name → (filename, source)
    let mut file_map: HashMap<String, (String, String)> = HashMap::new();
    for (filename, source) in &files {
        let key = normalize_specifier(
            Path::new(filename)
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or(filename),
        );
        file_map.insert(key, (filename.clone(), source.clone()));
    }

    // Transform each module and collect dependency info
    let transform_options = build_transform_options(
        &opts.jsx_runtime,
        &opts.jsx_factory,
        &opts.jsx_fragment,
        &opts.import_source,
        &opts.target,
    );
    let mut transformed: HashMap<String, String> = HashMap::new();
    let mut deps: HashMap<String, Vec<String>> = HashMap::new();

    for (key, (filename, source)) in &file_map {
        let allocator = Allocator::default();
        match transform_module(&allocator, source, filename, &transform_options) {
            Ok((code, imports)) => {
                transformed.insert(key.clone(), code);
                deps.insert(key.clone(), imports);
            }
            Err(errors) => {
                return Ok((atoms::error(), errors).encode(env));
            }
        }
    }

    // Topologically sort
    let order = match topo_sort(&deps) {
        Ok(order) => order,
        Err(msg) => return Ok((atoms::error(), vec![msg]).encode(env)),
    };

    // Concatenate in dependency order, wrapped in IIFE
    let mut output = String::new();
    if let Some(ref banner) = opts.banner {
        output.push_str(banner);
        output.push('\n');
    }
    output.push_str("(() => {\n");
    for key in &order {
        if let Some(code) = transformed.get(key) {
            output.push_str(code);
            output.push('\n');
        }
    }
    output.push_str("})();\n");
    if let Some(ref footer) = opts.footer {
        output.push_str(footer);
        output.push('\n');
    }

    // Apply define replacements
    if !opts.define.is_empty() {
        let allocator = Allocator::default();
        let source_type = SourceType::default();
        let ret = Parser::new(&allocator, &output, source_type)
            .with_options(ParseOptions {
                parse_regular_expression: true,
                ..ParseOptions::default()
            })
            .parse();

        if ret.errors.is_empty() {
            let mut program = ret.program;
            let scoping = SemanticBuilder::new()
                .build(&program)
                .semantic
                .into_scoping();

            let define_pairs: Vec<(&str, &str)> = opts
                .define
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();

            if let Ok(config) = ReplaceGlobalDefinesConfig::new(&define_pairs) {
                let _ = ReplaceGlobalDefines::new(&allocator, config).build(scoping, &mut program);
                let CodegenReturn { code, .. } = Codegen::new().build(&program);
                output = code;
            }
        }
    }

    // Minify
    let mut source_map: Option<String> = None;
    if opts.minify {
        let allocator = Allocator::default();
        let source_type = SourceType::default();
        let ret = Parser::new(&allocator, &output, source_type)
            .with_options(ParseOptions {
                parse_regular_expression: true,
                ..ParseOptions::default()
            })
            .parse();

        if !ret.errors.is_empty() {
            let msgs = format_errors(&ret.errors);
            return Ok((atoms::error(), msgs).encode(env));
        }

        let mut program = ret.program;
        let mut compress = CompressOptions::default();
        if opts.drop_console {
            compress.drop_console = true;
        }
        let options = MinifierOptions {
            mangle: Some(MangleOptions::default()),
            compress: Some(compress),
        };
        let min_ret = Minifier::new(options).minify(&allocator, &mut program);

        let mut codegen_opts = CodegenOptions::minify();
        if opts.sourcemap {
            codegen_opts.source_map_path = Some(PathBuf::from("bundle.js"));
        }
        let CodegenReturn { code, map, .. } = Codegen::new()
            .with_options(codegen_opts)
            .with_scoping(min_ret.scoping)
            .build(&program);
        output = code;
        if let Some(map) = map {
            source_map = Some(map.to_json_string());
        }
    } else if opts.sourcemap {
        // Sourcemap without minification
        let allocator = Allocator::default();
        let source_type = SourceType::default();
        let ret = Parser::new(&allocator, &output, source_type)
            .with_options(ParseOptions {
                parse_regular_expression: true,
                ..ParseOptions::default()
            })
            .parse();

        if ret.errors.is_empty() {
            let program = ret.program;
            let codegen_opts = CodegenOptions {
                source_map_path: Some(PathBuf::from("bundle.js")),
                ..CodegenOptions::default()
            };
            let CodegenReturn { code, map, .. } =
                Codegen::new().with_options(codegen_opts).build(&program);
            output = code;
            if let Some(map) = map {
                source_map = Some(map.to_json_string());
            }
        }
    }

    // Return {code, sourcemap} tuple when sourcemap requested, otherwise just code
    if let Some(ref map_json) = source_map {
        let result = Term::map_from_arrays(
            env,
            &[atoms::code().encode(env), atoms::sourcemap().encode(env)],
            &[output.encode(env), map_json.encode(env)],
        )
        .unwrap();
        Ok((atoms::ok(), result).encode(env))
    } else {
        Ok((atoms::ok(), output).encode(env))
    }
}

rustler::init!("Elixir.OXC.Native");
