# Superseded single-list C pilot

This pilot appended to the entire pending list. Fenrir appends to a separate rear list and shares the remaining front. The pilot copied 60 cells per search round and 55 per checker round. Instrumented Fenrir copied 31 and 28. The timings below cannot answer the matched-representation question. Both lanes used 5,000 corpus rounds.

| lane | compact C median | representation C median | Fenrir median | representation / compact | Fenrir / compact |
| --- | ---: | ---: | ---: | ---: | ---: |
| search | 2,145,551 ns | 2,930,867 ns | 14,201,375 ns | 1.35x | 6.60x |
| check | 1,295,319 ns | 2,216,614 ns | 8,102,682 ns | 1.70x | 6.31x |

