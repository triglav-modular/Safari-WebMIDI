#pragma once
#include <cstdlib>
#define CHECK(c) do { if (!(c)) std::abort(); } while (0)
#define DCHECK(c) CHECK(c)
#define CHECK_GT(a, b) CHECK((a) > (b))
#define DCHECK_EQ(a, b) CHECK((a) == (b))
#define DCHECK_GT(a, b) CHECK((a) > (b))
