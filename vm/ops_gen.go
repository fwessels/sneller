package vm

// Code generated automatically; DO NOT EDIT

const (
	opret                    bcop = 0
	opjz                     bcop = 1
	oploadk                  bcop = 2
	opsavek                  bcop = 3
	opxchgk                  bcop = 4
	oploadb                  bcop = 5
	opsaveb                  bcop = 6
	oploadv                  bcop = 7
	opsavev                  bcop = 8
	oploadzerov              bcop = 9
	opsavezerov              bcop = 10
	oploadpermzerov          bcop = 11
	opsaveblendv             bcop = 12
	oploads                  bcop = 13
	opsaves                  bcop = 14
	oploadzeros              bcop = 15
	opsavezeros              bcop = 16
	opbroadcastimmk          bcop = 17
	opfalse                  bcop = 18
	opandk                   bcop = 19
	opork                    bcop = 20
	opandnotk                bcop = 21
	opnandk                  bcop = 22
	opxork                   bcop = 23
	opnotk                   bcop = 24
	opxnork                  bcop = 25
	opbroadcastimmf          bcop = 26
	opbroadcastimmi          bcop = 27
	opabsf                   bcop = 28
	opabsi                   bcop = 29
	opnegf                   bcop = 30
	opnegi                   bcop = 31
	opsignf                  bcop = 32
	opsigni                  bcop = 33
	opsquaref                bcop = 34
	opsquarei                bcop = 35
	opbitnoti                bcop = 36
	opbitcounti              bcop = 37
	oproundf                 bcop = 38
	oproundevenf             bcop = 39
	optruncf                 bcop = 40
	opfloorf                 bcop = 41
	opceilf                  bcop = 42
	opaddf                   bcop = 43
	opaddimmf                bcop = 44
	opaddi                   bcop = 45
	opaddimmi                bcop = 46
	opsubf                   bcop = 47
	opsubimmf                bcop = 48
	opsubi                   bcop = 49
	opsubimmi                bcop = 50
	oprsubf                  bcop = 51
	oprsubimmf               bcop = 52
	oprsubi                  bcop = 53
	oprsubimmi               bcop = 54
	opmulf                   bcop = 55
	opmulimmf                bcop = 56
	opmuli                   bcop = 57
	opmulimmi                bcop = 58
	opdivf                   bcop = 59
	opdivimmf                bcop = 60
	oprdivf                  bcop = 61
	oprdivimmf               bcop = 62
	opdivi                   bcop = 63
	opdivimmi                bcop = 64
	oprdivi                  bcop = 65
	oprdivimmi               bcop = 66
	opmodf                   bcop = 67
	opmodimmf                bcop = 68
	oprmodf                  bcop = 69
	oprmodimmf               bcop = 70
	opmodi                   bcop = 71
	opmodimmi                bcop = 72
	oprmodi                  bcop = 73
	oprmodimmi               bcop = 74
	opaddmulimmi             bcop = 75
	opminvaluef              bcop = 76
	opminvalueimmf           bcop = 77
	opmaxvaluef              bcop = 78
	opmaxvalueimmf           bcop = 79
	opminvaluei              bcop = 80
	opminvalueimmi           bcop = 81
	opmaxvaluei              bcop = 82
	opmaxvalueimmi           bcop = 83
	opandi                   bcop = 84
	opandimmi                bcop = 85
	opori                    bcop = 86
	oporimmi                 bcop = 87
	opxori                   bcop = 88
	opxorimmi                bcop = 89
	opslli                   bcop = 90
	opsllimmi                bcop = 91
	opsrai                   bcop = 92
	opsraimmi                bcop = 93
	opsrli                   bcop = 94
	opsrlimmi                bcop = 95
	opsqrtf                  bcop = 96
	opcbrtf                  bcop = 97
	opexpf                   bcop = 98
	opexp2f                  bcop = 99
	opexp10f                 bcop = 100
	opexpm1f                 bcop = 101
	oplnf                    bcop = 102
	opln1pf                  bcop = 103
	oplog2f                  bcop = 104
	oplog10f                 bcop = 105
	opsinf                   bcop = 106
	opcosf                   bcop = 107
	optanf                   bcop = 108
	opasinf                  bcop = 109
	opacosf                  bcop = 110
	opatanf                  bcop = 111
	opatan2f                 bcop = 112
	ophypotf                 bcop = 113
	oppowf                   bcop = 114
	opcvtktof64              bcop = 115
	opcvtktoi64              bcop = 116
	opcvti64tok              bcop = 117
	opcvti64tof64            bcop = 118
	opcvtf64toi64            bcop = 119
	opfproundu               bcop = 120
	opfproundd               bcop = 121
	opcvti64tostr            bcop = 122
	opsortcmpvnf             bcop = 123
	opsortcmpvnl             bcop = 124
	opcmpv                   bcop = 125
	opcmpvk                  bcop = 126
	opcmpvimmk               bcop = 127
	opcmpvi64                bcop = 128
	opcmpvimmi64             bcop = 129
	opcmpvf64                bcop = 130
	opcmpvimmf64             bcop = 131
	opcmpltstr               bcop = 132
	opcmplestr               bcop = 133
	opcmpgtstr               bcop = 134
	opcmpgestr               bcop = 135
	opcmpltk                 bcop = 136
	opcmpltimmk              bcop = 137
	opcmplek                 bcop = 138
	opcmpleimmk              bcop = 139
	opcmpgtk                 bcop = 140
	opcmpgtimmk              bcop = 141
	opcmpgek                 bcop = 142
	opcmpgeimmk              bcop = 143
	opcmpeqf                 bcop = 144
	opcmpeqimmf              bcop = 145
	opcmpltf                 bcop = 146
	opcmpltimmf              bcop = 147
	opcmplef                 bcop = 148
	opcmpleimmf              bcop = 149
	opcmpgtf                 bcop = 150
	opcmpgtimmf              bcop = 151
	opcmpgef                 bcop = 152
	opcmpgeimmf              bcop = 153
	opcmpeqi                 bcop = 154
	opcmpeqimmi              bcop = 155
	opcmplti                 bcop = 156
	opcmpltimmi              bcop = 157
	opcmplei                 bcop = 158
	opcmpleimmi              bcop = 159
	opcmpgti                 bcop = 160
	opcmpgtimmi              bcop = 161
	opcmpgei                 bcop = 162
	opcmpgeimmi              bcop = 163
	opisnanf                 bcop = 164
	opchecktag               bcop = 165
	optypebits               bcop = 166
	opisnull                 bcop = 167
	opisnotnull              bcop = 168
	opistrue                 bcop = 169
	opisfalse                bcop = 170
	opeqslice                bcop = 171
	opequalv                 bcop = 172
	opeqv4mask               bcop = 173
	opeqv4maskplus           bcop = 174
	opeqv8                   bcop = 175
	opeqv8plus               bcop = 176
	opleneq                  bcop = 177
	opdateaddmonth           bcop = 178
	opdateaddmonthimm        bcop = 179
	opdateaddyear            bcop = 180
	opdateaddquarter         bcop = 181
	opdatediffparam          bcop = 182
	opdatediffmonthyear      bcop = 183
	opdateextractmicrosecond bcop = 184
	opdateextractmillisecond bcop = 185
	opdateextractsecond      bcop = 186
	opdateextractminute      bcop = 187
	opdateextracthour        bcop = 188
	opdateextractday         bcop = 189
	opdateextractdow         bcop = 190
	opdateextractdoy         bcop = 191
	opdateextractmonth       bcop = 192
	opdateextractquarter     bcop = 193
	opdateextractyear        bcop = 194
	opdatetounixepoch        bcop = 195
	opdatetruncmillisecond   bcop = 196
	opdatetruncsecond        bcop = 197
	opdatetruncminute        bcop = 198
	opdatetrunchour          bcop = 199
	opdatetruncday           bcop = 200
	opdatetruncdow           bcop = 201
	opdatetruncmonth         bcop = 202
	opdatetruncquarter       bcop = 203
	opdatetruncyear          bcop = 204
	opunboxts                bcop = 205
	opboxts                  bcop = 206
	optimelt                 bcop = 207
	optimegt                 bcop = 208
	opconsttm                bcop = 209
	optmextract              bcop = 210
	opwidthbucketf           bcop = 211
	opwidthbucketi           bcop = 212
	optimebucketts           bcop = 213
	opgeohash                bcop = 214
	opgeohashimm             bcop = 215
	opgeotilex               bcop = 216
	opgeotiley               bcop = 217
	opgeotilees              bcop = 218
	opgeotileesimm           bcop = 219
	opgeodistance            bcop = 220
	opconcatlenget1          bcop = 221
	opconcatlenget2          bcop = 222
	opconcatlenget3          bcop = 223
	opconcatlenget4          bcop = 224
	opconcatlenacc1          bcop = 225
	opconcatlenacc2          bcop = 226
	opconcatlenacc3          bcop = 227
	opconcatlenacc4          bcop = 228
	opallocstr               bcop = 229
	opappendstr              bcop = 230
	opfindsym                bcop = 231
	opfindsym2               bcop = 232
	opfindsym2rev            bcop = 233
	opfindsym3               bcop = 234
	opblendv                 bcop = 235
	opblendrevv              bcop = 236
	opblendnum               bcop = 237
	opblendnumrev            bcop = 238
	opblendslice             bcop = 239
	opblendslicerev          bcop = 240
	opunpack                 bcop = 241
	opunsymbolize            bcop = 242
	opunboxktoi64            bcop = 243
	opunboxcoercef64         bcop = 244
	opunboxcoercei64         bcop = 245
	opunboxcvtf64            bcop = 246
	opunboxcvti64            bcop = 247
	optoint                  bcop = 248
	optof64                  bcop = 249
	opboxfloat               bcop = 250
	opboxint                 bcop = 251
	opboxmask                bcop = 252
	opboxmask2               bcop = 253
	opboxmask3               bcop = 254
	opboxstring              bcop = 255
	opboxlist                bcop = 256
	opmakelist               bcop = 257
	opmakestruct             bcop = 258
	ophashvalue              bcop = 259
	ophashvalueplus          bcop = 260
	ophashmember             bcop = 261
	ophashlookup             bcop = 262
	opaggandk                bcop = 263
	opaggork                 bcop = 264
	opaggsumf                bcop = 265
	opaggsumi                bcop = 266
	opaggminf                bcop = 267
	opaggmini                bcop = 268
	opaggmaxf                bcop = 269
	opaggmaxi                bcop = 270
	opaggandi                bcop = 271
	opaggori                 bcop = 272
	opaggxori                bcop = 273
	opaggcount               bcop = 274
	opaggbucket              bcop = 275
	opaggslotandk            bcop = 276
	opaggslotork             bcop = 277
	opaggslotaddf            bcop = 278
	opaggslotaddi            bcop = 279
	opaggslotavgf            bcop = 280
	opaggslotavgi            bcop = 281
	opaggslotminf            bcop = 282
	opaggslotmini            bcop = 283
	opaggslotmaxf            bcop = 284
	opaggslotmaxi            bcop = 285
	opaggslotandi            bcop = 286
	opaggslotori             bcop = 287
	opaggslotxori            bcop = 288
	opaggslotcount           bcop = 289
	oplitref                 bcop = 290
	opauxval                 bcop = 291
	opsplit                  bcop = 292
	optuple                  bcop = 293
	opdupv                   bcop = 294
	opzerov                  bcop = 295
	opobjectsize             bcop = 296
	opCmpStrEqCs             bcop = 297
	opCmpStrEqCi             bcop = 298
	opCmpStrEqUTF8Ci         bcop = 299
	opSkip1charLeft          bcop = 300
	opSkip1charRight         bcop = 301
	opSkipNcharLeft          bcop = 302
	opSkipNcharRight         bcop = 303
	opTrimWsLeft             bcop = 304
	opTrimWsRight            bcop = 305
	opTrim4charLeft          bcop = 306
	opTrim4charRight         bcop = 307
	opContainsSuffixCs       bcop = 308
	opContainsSuffixCi       bcop = 309
	opContainsSuffixUTF8Ci   bcop = 310
	opContainsPrefixCs       bcop = 311
	opContainsPrefixCi       bcop = 312
	opContainsPrefixUTF8Ci   bcop = 313
	opLengthStr              bcop = 314
	opSubstr                 bcop = 315
	opSplitPart              bcop = 316
	opMatchpatCs             bcop = 317
	opMatchpatCi             bcop = 318
	opMatchpatUTF8Ci         bcop = 319
	opIsSubnetOfIP4          bcop = 320
	opDfaT6                  bcop = 321
	opDfaT7                  bcop = 322
	opDfaT8                  bcop = 323
	opDfaT6Z                 bcop = 324
	opDfaT7Z                 bcop = 325
	opDfaT8Z                 bcop = 326
	opDfaLZ                  bcop = 327
	opslower                 bcop = 328
	opsupper                 bcop = 329
	opsadjustsize            bcop = 330
	opaggapproxcount         bcop = 331
	optrap                   bcop = 332
	_maxbcop                      = 333
)
