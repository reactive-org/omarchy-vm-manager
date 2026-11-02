#include "DevVMYAML.h"
#include "yaml.h"

struct dvm_yaml_parser {
    yaml_parser_t parser;
    yaml_event_t event;
    int has_event;
    uint8_t *input;
};

dvm_yaml_parser *dvm_yaml_create(const uint8_t *bytes, size_t length) {
    if (!bytes || length > 262144) return NULL;
    dvm_yaml_parser *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->input = malloc(length ? length : 1);
    if (!p->input || !yaml_parser_initialize(&p->parser)) {
        free(p->input); free(p); return NULL;
    }
    memcpy(p->input, bytes, length);
    yaml_parser_set_input_string(&p->parser, p->input, length);
    yaml_parser_set_encoding(&p->parser, YAML_UTF8_ENCODING);
    return p;
}

int dvm_yaml_next(dvm_yaml_parser *p, dvm_yaml_event *out) {
    memset(out, 0, sizeof(*out));
    if (p->has_event) yaml_event_delete(&p->event);
    p->has_event = 0;
    if (!yaml_parser_parse(&p->parser, &p->event)) {
        // Never export LibYAML's source-bearing error strings.
        out->line = p->parser.problem_mark.line + 1;
        out->column = p->parser.problem_mark.column + 1;
        return 0;
    }
    p->has_event = 1;
    yaml_event_t *e = &p->event;
    out->line = e->start_mark.line + 1;
    out->column = e->start_mark.column + 1;
    switch (e->type) {
        case YAML_STREAM_START_EVENT: out->kind = 1; break;
        case YAML_STREAM_END_EVENT: out->kind = 2; break;
        case YAML_DOCUMENT_START_EVENT:
            out->kind = 3;
            out->forbidden = e->data.document_start.version_directive != NULL ||
                e->data.document_start.tag_directives.start != e->data.document_start.tag_directives.end;
            break;
        case YAML_DOCUMENT_END_EVENT: out->kind = 4; break;
        case YAML_SCALAR_EVENT:
            out->kind = 5;
            out->value = e->data.scalar.value;
            out->length = e->data.scalar.length;
            out->plain = e->data.scalar.style == YAML_PLAIN_SCALAR_STYLE;
            out->forbidden = e->data.scalar.anchor != NULL || e->data.scalar.tag != NULL;
            break;
        case YAML_SEQUENCE_START_EVENT:
            out->kind = 6;
            out->forbidden = e->data.sequence_start.anchor != NULL || e->data.sequence_start.tag != NULL;
            break;
        case YAML_SEQUENCE_END_EVENT: out->kind = 7; break;
        case YAML_MAPPING_START_EVENT:
            out->kind = 8;
            out->forbidden = e->data.mapping_start.anchor != NULL || e->data.mapping_start.tag != NULL;
            break;
        case YAML_MAPPING_END_EVENT: out->kind = 9; break;
        case YAML_ALIAS_EVENT: out->kind = 10; out->forbidden = 1; break;
        default: return 0;
    }
    return 1;
}

void dvm_yaml_destroy(dvm_yaml_parser *p) {
    if (!p) return;
    if (p->has_event) yaml_event_delete(&p->event);
    yaml_parser_delete(&p->parser);
    // Input can contain sensitive data; it is never logged or retained globally.
    free(p->input);
    free(p);
}
