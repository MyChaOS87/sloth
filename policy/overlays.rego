package main

import rego.v1

# Disjoint leaf/array keys between inline helm.values and $private/values/*.yaml
deny contains msg if {
	some e in doc_entries
	filepath := e.path
	doc := e.doc
	object.get(doc, "kind", "") == "Application"
	some src in app_sources(doc)
	vals := src.helm.values
	yaml.is_valid(vals)
	some vf in src.helm.valueFiles
	startswith(vf, "$private/")
	rel := trim_prefix(vf, "$private/")
	some pe in doc_entries
	priv_path := pe.path
	priv_doc := pe.doc
	endswith(concat("", ["/", priv_path]), concat("", ["/", rel]))
	inline_doc := yaml.unmarshal(vals)
	some pa in non_object_paths(inline_doc)
	some pb in non_object_paths(priv_doc)
	same_or_prefix(pa, pb)
	msg := sprintf("%s: inline helm.values overlaps with %s at key %q", [filepath, priv_path, concat(".", pa)])
}
