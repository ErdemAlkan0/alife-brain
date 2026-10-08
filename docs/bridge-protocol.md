# Dosya köprüsü protokolü (v1)

Uygulama: Lua `mod/Contents/mods/ALifeBrain/42/media/lua/shared/ALifeBrain/Bridge.lua`,
Python `sidecar/alifebrain_sidecar/` (`protocol.py`, `files.py`, `app.py`).

## Dosyalar (hepsi `Zomboid/Lua/` içinde, düz ad)

| Dosya | Yazan | Okuyan | Nasıl |
|---|---|---|---|
| `alifebrain_req.txt` | Lua (ekleme) | sidecar | Sidecar dosyayı **yeniden adlandırarak** sahiplenir; Lua bir sonraki yazışta yenisini oluşturur. Lua hiçbir zaman kesme/temizleme yapmaz. |
| `alifebrain_req.processing` | sidecar | sidecar | Sahiplenilen parti; okunduktan sonra silinir. Çökmeden kalırsa önce o işlenir. |
| `alifebrain_res.txt` | sidecar (atomik değiştirme) | Lua (~250 ms'de bir) | `alifebrain_res.tmp`'ye yazılır, `os.replace` ile değiştirilir. |

İçerik JSON satırlarıdır ama uzantı `.txt`'dir: B42'de `getFileWriter` yalnızca `txt, ini, cfg, json, lua, log`
uzantılarına yazar, `.jsonl` gibi diğerlerini hata vermeden reddeder.
| `alifebrain_res.tmp` | sidecar | — | Geçici. |

Windows'ta oyun bir dosyayı açık tuttuğu sürece yeniden adlandırma/değiştirme başarısız olur; sidecar bu durumda
bir sonraki adımda tekrar dener. Böylece yarım satır asla okunmaz. Sidecar bu dört dosya dışında `Zomboid/Lua`'ya
dokunmaz.

Bütün satırlar **ASCII** JSON'dur (ASCII dışı karakterler `\uXXXX`), bu yüzden dosya kodlaması önemli değildir.

## Lua → sidecar (istek satırı)

```json
{"v":1,"id":"<sess>:<seq>","sess":"<sess>","type":"ping","ts":1759951234567,"data":{...},"ack":{"sid":"a1b2c3d4","rseq":7}}
```

- `sess`: oyun açılışında üretilir (`<ms>-<rastgele>`). Her yeni oyun yüklemesinde değişir.
- `id`: oturum içinde benzersiz; cevaplar `re` alanında buna atıf yapar.
- `ts`: Lua'nın `getTimestampMs()` değeri (duvar saati, ms).
- `ack` (isteğe bağlı): Lua'nın o sidecar örneğinden (`sid`) işlediği en büyük `rseq`. Her mesaja eklenir; gönderilecek
  başka bir şey yoksa en fazla saniyede bir ayrı bir `ack` mesajı gider.
- `type` değerleri (v1): `hello`, `ping`, `event`, `ack`. `event` ve `ack` için cevap satırı yazılmaz
  (`event` hatalıysa yazılır).

## Sidecar → Lua (cevap dosyası)

İlk satır **her zaman** durum satırıdır, sonrakiler onaylanmamış mesajlardır:

```json
{"v":1,"type":"status","sid":"a1b2c3d4","beat":42,"ts":1759951234600,"ver":"0.1.0","sess":"<son görülen oturum>"}
{"v":1,"type":"res","rseq":7,"re":"<istek id>","ok":true,"data":{...}}
{"v":1,"type":"res","rseq":8,"re":"<istek id>","ok":false,"error":"unknown_type"}
{"v":1,"type":"push","rseq":9,"sess":"<oturum>","kind":"...","data":{...}}
```

- `sid`: sidecar süreci başına rastgele. Değişirse Lua `rseq` takibini sıfırlar.
- `beat`: her yayında artar; sidecar boşta bile saniyede bir yayın yapar.
- `rseq`: sidecar örneği içinde artan sıra; Lua yalnızca `lastRseq`'ten büyükleri işler (tekrarlar zararsız).
- Sidecar, onaylanan (`rseq ≤ ack`), 120 s'den eski veya eski oturumlara ait mesajları dosyadan çıkarır.

## Canlılık ve geri düşüş

- Lua, durum satırındaki `ts` kendi saatine 4 s'den yakınsa **veya** `beat` son 4 s içinde değiştiyse sidecar'ı
  çevrimiçi sayar.
- Çevrimdışıyken Lua dosyaya **hiç yazmaz**: `request()` hemen `nil, "offline"` döner (çağıran hazır repliğe düşer),
  `send("event")` olayları bellekte en fazla 200 kayıtlık bir kuyrukta tutar ve bağlantı gelince orijinal `ts` ile
  gönderir.
- Çevrimiçiyken düşerse bekleyen bütün istekler `false, "offline"` ile sonuçlanır.
- İstek zaman aşımı varsayılan 8 s (`ping` 5 s). Sidecar, `event`/`ack` dışındaki 30 s'den eski istekleri atar.

## Sınırlar

- Satır başına en fazla 16000 karakter; JSON derinliği en fazla 64.
- Lua giden kuyruğu 256 satır; sidecar bekleyen cevaplar 500.
- Aynı anda tek sidecar: veri klasöründeki `sidecar.lock` dosyası kilitlenir.
