package main

import rego.v1

norm_path(p) := replace(p, "\\", "/")

# conftest --combine wraps each parsed document as {"path": "<file>", "contents": <doc>}.
raw_entries contains {"path": norm_path(e.path), "contents": e.contents} if {
	is_array(input)
	some e in input
	is_object(e)
	is_string(object.get(e, "path", null))
}

doc_entries contains {"path": e.path, "doc": e.contents} if {
	some e in raw_entries
	is_object(e.contents)
}

doc_entries contains {"path": e.path, "doc": d} if {
	some e in raw_entries
	is_array(e.contents)
	some d in e.contents
	is_object(d)
}

app_sources(doc) := doc.spec.sources if is_array(object.get(doc.spec, "sources", null))
app_sources(doc) := [doc.spec.source] if is_object(object.get(doc.spec, "source", null))

known_projects contains e.doc.metadata.name if {
	some e in doc_entries
	object.get(e.doc, "kind", "") == "AppProject"
	is_string(object.get(object.get(e.doc, "metadata", {}), "name", null))
}

is_authelia_users_secret(filepath, doc) if {
	endswith(concat("", ["/", norm_path(filepath)]), "/deployments/oidc/authelia-config/users-secret.yaml")
	object.get(object.get(doc, "metadata", {}), "name", "") == "authelia-users"
	object.get(object.get(doc, "metadata", {}), "namespace", "") == "oidc"
}

leaf_or_array_val(v) if not is_object(v)
leaf_or_array_val(v) if {
	is_object(v)
	count(v) == 0
}

non_object_paths(obj) := {p |
	some p, v
	walk(obj, [p, v])
	count(p) > 0
	leaf_or_array_val(v)
	every seg in p {
		is_string(seg)
	}
}

same_or_prefix(a, b) if {
	count(a) <= count(b)
	every i, seg in a {
		b[i] == seg
	}
}

same_or_prefix(a, b) if {
	count(b) < count(a)
	every i, seg in b {
		a[i] == seg
	}
}
