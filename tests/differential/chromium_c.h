#include <stddef.h>
#include <stdint.h>
int cr_valid(const uint8_t* d, size_t n);
size_t cr_length(uint8_t status);
size_t cr_parse(const uint8_t* d, size_t n, uint8_t* out, size_t cap);
size_t cr_translate(const uint8_t* d, size_t n, uint32_t* out, size_t cap);
size_t cr_dispatch(const uint32_t* w, size_t n, uint8_t* out, size_t cap);
size_t cr_queue(int running, const uint8_t* d, size_t n, const size_t* cuts, size_t ncuts, uint8_t* out, size_t cap);
