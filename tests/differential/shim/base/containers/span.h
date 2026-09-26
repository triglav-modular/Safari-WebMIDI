#pragma once
#include <span>
namespace base {
template <class T, std::size_t E = std::dynamic_extent> using span = std::span<T, E>;
}
