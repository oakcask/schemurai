package main

allowed_types := "build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test"

label := object.get(input, "label", "subject")

subjects := object.get(input, "subjects", [])

text_label := object.get(input, "text_label", "text")

texts := object.get(input, "texts", [])

valid_subject(subject) if {
	regex.match(sprintf("^(%s)(\\([a-z0-9._-]+\\))?!?: .+$", [allowed_types]), subject)
}

docs_has_scope(subject) if {
	regex.match(`^docs\(`, subject)
}

product_type_has_ci_related_scope(subject) if {
	regex.match(`^(feat|fix)\((ci|workflow|workflows|actions)\)!?: .+$`, subject)
}

deny contains msg if {
	not is_array(subjects)
	msg := "subjects must be an array"
}

deny contains msg if {
	is_array(subjects)
	some index
	subject := subjects[index]
	not is_string(subject)
	msg := sprintf("%s at index %d must be a string", [label, index])
}

deny contains msg if {
	is_array(subjects)
	some subject in subjects
	is_string(subject)
	subject != ""
	not valid_subject(subject)
	msg := sprintf("Invalid %s: %s. Must follow Conventional Commits, for example: feat(cli): add dry-run option", [label, subject])
}

deny contains msg if {
	is_array(subjects)
	some subject in subjects
	is_string(subject)
	subject != ""
	valid_subject(subject)
	docs_has_scope(subject)
	msg := sprintf("Invalid %s: %s. docs commits must not include a scope", [label, subject])
}

deny contains msg if {
	is_array(subjects)
	some subject in subjects
	is_string(subject)
	subject != ""
	valid_subject(subject)
	product_type_has_ci_related_scope(subject)
	msg := sprintf("Invalid %s: %s. Use chore(ci) for CI workflow, pipeline, and automation changes; reserve feat and fix for product changes", [label, subject])
}

deny contains msg if {
	not is_array(texts)
	msg := "texts must be an array"
}

deny contains msg if {
	is_array(texts)
	some text in texts
	not is_string(text)
	msg := "text entries must be strings"
}

deny contains msg if {
	is_array(texts)
	some text in texts
	is_string(text)
	contains(text, `\n\n`)
	msg := sprintf("Invalid %s: use real line breaks instead of literal \\n", [text_label])
}
