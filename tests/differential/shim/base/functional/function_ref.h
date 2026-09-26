#pragma once
#include <functional>
namespace base { template <class Sig> using FunctionRef = std::function<Sig>; }
