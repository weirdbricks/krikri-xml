# AGENTS.md

Guidance for AI agents working in this repository.

## What this project is

**krikri-xml** is a clean-room XML 1.0 (Fifth Edition) parser plus XPath 1.0
evaluator written in pure Crystal. The defining constraint: **no C
dependencies**. The Crystal stdlib `xml` module links libxml2; this shard
deliberately does not link any native library. The W3C specifications
(REC-xml-20081126, REC-xpath-19991116, and xml-names) are the *only* reference
- do not port code from other implementations (libxml2, expat, Nokogiri,
etc.) and do not consult their behavior as authority; the spec decides.

## Commands

```sh
crystal spec                          # full test suite (the only required check)
crystal spec spec/xpath_spec.cr       # single spec file
shards install                        # needed once before ameba
crystal lib/ameba/bin/ameba.cr        # lint (ameba is not on PATH)
crystal tool format src spec          # formatter; run before committing
crystal run bench/bench.cr --release  # benchmark vs ysbaddaden/xml.cr
```

CI (`.github/workflows/ci.yml`) runs only `crystal spec` on
`crystallang/crystal:1.21.0-alpine`. Crystal `>= 1.10.0` per `shard.yml`.

The conformance spec (`spec/conformance_spec.cr`) reads
`testdata/xmlts20130923.zip` (the W3C XML Conformance Test Suite, vendored,
committed as a binary). It parses each sub-catalog with this parser itself and
is data-driven from `TEST` entries; it takes noticeably longer than the unit
specs.

## Architecture

```
src/krikri-xml.cr          entry point: requires nodes, parser, xpath
src/kxml/nodes.cr          DOM: Document, Element, Text, CData, Comment,
                           ProcessingInstruction, DocumentType, Attribute,
                           mutation API, serialization (to_xml)
src/kxml/parser.cr         strict non-recovering XML 1.0 (5th ed.) parser;
                           also the scanner, entity//DTD handling
src/kxml/xpath.cr          public XPath facade
src/kxml/xpath/base.cr     XPath value model + string-value/document-order rules
src/kxml/xpath/lexer.cr    XPath 1.0 lexer
src/kxml/xpath/parser.cr   XPath 1.0 grammar -> AST
src/kxml/xpath/evaluator.c evaluation over the KXML DOM
```

Key invariants:

- **Document order**: every node and attribute carries a `doc_order : Int32`
  assigned by the parser (creation order) and maintained by the mutation API
  (`Document#allocate_order` recomputes the max and assigns the next value).
  XPath node-sets are sorted and deduplicated solely via `doc_order`, so any
  new node-creation path **must** call `allocate_order` or XPath ordering
  breaks. `NodeSet = Array(Node | Attribute)`; attributes are first-class
  XPath nodes.
- **Parser is byte-driven**: `KXML.decode_char_at` (parser.cr) decodes UTF-8
  at a byte position because `String#char_at` indexes by character and would
  be wrong for the scanner. Keep the scanner operating on byte positions.
- **Strict, non-recovering**: any well-formedness violation raises
  `KXML::Error` (which carries `line`, `column`, `context`). There is no
  recovery mode and none should be added.
- **Namespaces are always enforced** (NS-aware reading), even in tests where
  the W3C suite disagrees; see "known divergences" below.

## Deliberate policies (do not "fix" these)

- As of commit `ae47898`, the formerly deliberate XPath limitations were
  closed: variable references resolve via the optional `vars` binding map on
  `XPath.evaluate`, the namespace axis works via synthesized `NamespaceNode`s
  built from the context element's in-scope bindings (string-value is the
  URI), and `id()` resolves tokens through `Document#id_attribute_names`
  (ATTLIST `type="ID"` declarations recorded during parse). Update the README
  status section if behavior changes again.
- External entity / external subset fetching is deliberately unsupported
  (offline use); references to external entities are recognized and rejected.
- Parser limits as configurable constants on `KXML::Parser`:
  `MAX_ELEMENT_DEPTH` (2_048, matching libxml2's XML_MAX_DEPTH; parsing is
  recursive, so this must stay low enough that the guard raises before the
  call stack overflows - empirical overflow starts around depth ~6,000 on an
  8 MB stack), `MAX_ENTITY_DEPTH` (64), `MAX_EXPANDED_BYTES` (10M) -
  billion-laughs guards.
- XML 1.1 documents are rejected (this is a 1.0 processor).
- The serializer is spec-shaped, not libxml2-shaped; byte-identical output
  with libxml2/lxml is *not* a goal (though `to_xml(pretty:)` mirrors
  libxml2's FORMAT mode semantics).
- Predefined entities are stored as spec-required replacement texts with
  double escaping for `lt`/`amp` (`&#60;`, `&#38;`) so references re-expand
  to data, never markup - keep this invariant when touching entity handling.

## Testing conventions

- Specs in `spec/`, plain Crystal spec DSL, one file per feature area
  (parser, entities, doctype, namespaces, normalization, mutation, xpath,
  conformance).
- `spec/spec_helper.cr` provides `expect_error(source, message)` returning
  the raised `KXML::Error` - use it rather than raw `expect_raises`.
- **The conformance suite's failures are load-bearing.**
  `spec/conformance_spec.cr` has a `KNOWN_DIVERGENCES` hash mapping test IDs
  to documented reasons, plus assertions that (a) no *unexplained* failure
  occurs, (b) every documented divergence is *still* diverging, and (c) skips
  stay a minority. If you make the parser more conformant and a divergence
  disappears, you must remove its `KNOWN_DIVERGENCES` entry or the spec
  fails with "documented divergences no longer failing". Conversely, any new
  failure must be either fixed or added there with a reason.
- Mutating/fixing parser behavior can shift conformance counts; run the full
  `crystal spec`, not just the touched spec file.

## Lint configuration (.ameba.yml)

Ameba exceptions are deliberate and commented:
- `Lint/NotNil` excluded for all specs (`not_nil!` is idiomatic there).
- `Metrics/CyclomaticComplexity` excluded for `parser.cr` and all XPath
  files: they are single-dispatch tables (char-class membership tests, case
  statements over the XPath grammar) where splitting would obscure the spec
  structure they mirror. Do not refactor spec-mirroring code to satisfy the
  linter.

## Gotchas

- The DOM's `Document#children` is synthesized (`misc_before + root +
  misc_after`); it is not a stored list. Mutations go through the explicit
  mutation API (`append_child`, `add_next_sibling`, `add_prev_sibling`,
  `unlink`, `text=`, `set_attribute`, `delete_attribute`) which mirrors
  libxml2 move semantics, not by pushing onto arrays directly.
- `Element#[]` and `#[]?` both return `String?`; prefer `#[]?` in new code
  for clarity.
- Clark notation (`{uri}local`) is accepted by `create_element` and
  `set_attribute`; when no in-scope binding exists, a new `xmlns:nsN`
  declaration is generated on the element itself (libxml2
  `xmlSearchNsByHref`/`xmlNewNs` behavior).
- `spec_helper.cr` only requires the shard source; the conformance spec
  additionally requires `compress/zip` from the stdlib.
- A stray compiled binary at repo root (`krikri-xml`) is gitignored - do not
  track it.
