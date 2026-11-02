#ifndef DEV_VM_YAML_H
#define DEV_VM_YAML_H
#include <stddef.h>
#include <stdint.h>

// No composer: callers can reject aliases/tags/depth before constructing a tree.
typedef struct dvm_yaml_parser dvm_yaml_parser;
typedef struct {
    int kind; // stream start/end, document start/end, scalar, sequence start/end, mapping start/end, alias
    const uint8_t *value; // valid only until the next next()/destroy()
    size_t length;
    int plain;
    int forbidden; // anchor, explicit tag or document directive
    size_t line;
    size_t column;
} dvm_yaml_event;
dvm_yaml_parser *dvm_yaml_create(const uint8_t *bytes, size_t length);
int dvm_yaml_next(dvm_yaml_parser *parser, dvm_yaml_event *event);
void dvm_yaml_destroy(dvm_yaml_parser *parser);
#endif
