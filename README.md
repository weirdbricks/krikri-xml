# krikri-xml

A clean-room XML 1.0 (Fifth Edition) parser in pure Crystal. **No C
dependencies** - the stdlib `xml` module links libxml2; this shard does not
link any native library at all.

## Provenance

Implemented directly from the W3C specification
[REC-xml-20081126](https://www.w3.org/TR/2008/REC-xml-20081126/) (Extensible
Markup Language (XML) 1.0, Fifth Edition) plus
[Namespaces in XML 1.0](https://www.w3.org/TR/xml-names/). No code from other
implementations was consulted or ported; the specification is the only
reference.

## Status

- Strict, non-recovering well-formedness parsing (like lxml: any
  well-formedness violation raises).
- DOM tree (`Document`, `Element`, `Text`, `CData`, `Comment`,
  `ProcessingInstruction`, `DocumentType`).
- Full internal DTD subset processing: ENTITY/ENTITY % declarations,
  ATTLIST defaults (with per-type attribute-value normalization), and the
  4.4/4.5 reference treatment (Included / Included in literal / Bypassed /
  Forbidden) exactly as specified.
- Namespaces in XML 1.0 (default namespace, prefixed bindings, undeclaring,
  conflict detection).
- Basic `to_xml` serialization.

Not implemented (yet):

- XPath 1.0 evaluation.
- External entity / external subset fetching (references to external
  entities are recognized and rejected - deliberate, since krikri's use is
  offline).
- Serializer fidelity to libxml2/lxml byte output (the current serializer is
  spec-shaped, not libxml2-shaped).

## Usage

```crystal
require "krikri-xml"

doc = KXML.parse(%(<root><child a="1">text</child></root>))
doc.root.not_nil!.elements[0]["a"] # => "1"

begin
  KXML.parse("<root><a></root>")
rescue e : KXML::Error
  e.line   # line number of the violation
  e.column # column of the violation
end
```

## Deliberate parser policies

The spec mandates behaviors; some operational limits are parser policy and
configurable constants on `KXML::Parser`:

- `MAX_ELEMENT_DEPTH` (10_000) - guards against stack exhaustion on deeply
  nested documents.
- `MAX_ENTITY_DEPTH` (64) and `MAX_EXPANDED_BYTES` (10M) - guards against
  billion-laughs attacks. The spec permits a processor to impose limits.
- XML version `1.1` documents are rejected (this is a 1.0 processor).
- Character references and names follow the Fifth Edition productions
  exactly (NameChar per erratum E09).

## Conformance

The W3C XML Conformance Test Suite (`xmlts20130923.zip`, vendored under
`testdata/`) runs as a data-driven spec: `spec/conformance_spec.cr` reads the
sub-catalog files from the zip, parses each catalog with this parser itself,
and runs every test file whose expectations this parser can honestly check.

Results across the 15 sub-catalogs (James Clark xmltest, OASIS/NIST, Sun,
IBM, Edinburgh errata-2e/3e/4e, Richard Tobin's Namespaces 1.0 + errata):

- **1,668 passed** of 1,981 executed (well-formed accepted, not-wf rejected).
- **313 documented divergences** - every one enumerated with its reason in
  `spec/conformance_spec.cr` (`KNOWN_DIVERGENCES`). They fall into three
  classes:
  - 300 IBM PITarget tests expecting 4th-edition Letter/NameChar classes;
    this parser implements the 5th-edition `NameStartChar` production, under
    which those characters are legal (the suite's own errata-4e tests agree).
  - Colon-containing names the suite's Name-production tests accept but a
    Namespaces-aware processor must reject (the suite is self-contradictory
    here; this parser follows the NS-aware reading, matching
    rmt-ns10-042/043/044).
  - Encoding-declaration compatibility checks, which require real
    transcoding this parser does not perform.
- **319 skipped** - tests that require external entities (`ENTITIES`
  parameter/both/general) or non-UTF-8 encodings, which the parser
  deliberately does not support.

## Development

```sh
crystal spec
```
