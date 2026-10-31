#ifndef SCHEMURAI_PROTOCOL_H
#define SCHEMURAI_PROTOCOL_H
enum {
#define SN_OPCODE(name, symbol, value) SN_OP_##name = value,
#define SN_CONSTANT(name, value) SN_##name = value,
#define SN_FIELD(name, symbol, value) SN_FIELD_##name = value,
#include "protocol.def"
#undef SN_OPCODE
#undef SN_CONSTANT
#undef SN_FIELD
};
#endif
