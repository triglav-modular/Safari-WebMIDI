#pragma once
namespace base { struct HistogramBase { using Sample32 = int; }; }
#define UMA_HISTOGRAM_COUNTS_1M(name, sample) do { (void)(sample); } while (0)
