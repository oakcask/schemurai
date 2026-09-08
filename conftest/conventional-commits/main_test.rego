package main

valid_input := {
	"label": "commit subject",
	"subjects": ["fix: preserve real line breaks"],
	"text_label": "commit message",
	"texts": ["Summary\n\nDetails"],
}

test_accepts_real_blank_lines if {
	violations := deny with input as valid_input
	count(violations) == 0
}

test_rejects_literal_escaped_blank_lines if {
	invalid := object.union(valid_input, {"texts": [`Summary\n\nDetails`]})
	violations := deny with input as invalid
	violations["Invalid commit message: use real line breaks instead of literal \\n"]
}

test_rejects_non_array_texts if {
	invalid := object.union(valid_input, {"texts": "Summary"})
	violations := deny with input as invalid
	violations["texts must be an array"]
}

test_rejects_non_string_text_entries if {
	invalid := object.union(valid_input, {"texts": [null]})
	violations := deny with input as invalid
	violations["text entries must be strings"]
}
