# Serialization and codecs

A codec turns a Ruby object into bytes and back, and decides the `content-type` the
message carries. One setting names a built-in; anything else is an object.

```yaml
# config/acemq.yml
shared:
  format: json
```

```ruby
# config/environments/production.rb — for anything a name cannot carry
config.acemq.codec = AceMQ::AMQP::CompositeCodec.new(
  AceMQ::AMQP::JSONCodec.new, AceMQ::AMQP::YAMLCodec.new
)
```

`codec` wins over `format`. Both are one per connection, which is one per process,
and a consumer class can override it for its own queue.

## The names `format` accepts

`AceMQ::AMQP::Codecs.names` is the list, and it is exactly this:

| `format` | Content type | |
|---|---|---|
| `json` | `application/json` | The default. Also reads `text/json`, `…+json`, and a message with **no** content type |
| `string` | `text/plain; charset=utf-8` | Also reads any `text/…` |
| `bytes` | `application/octet-stream` | Reads everything, including untyped |
| `yaml` | `application/yaml` | Also `application/x-yaml`, `text/yaml`, `text/x-yaml`, `…+yaml` |
| `toml` | `application/toml` | Also `text/toml`, `…+toml` |
| `xml` | `application/xml` | Also `text/xml`, `…+xml`. Requires `rexml` |

A name that is not on that list raises on boot, and names the list:

```
ArgumentError: no codec named "msgpack" is registered; known: bytes, json, string, toml, xml, yaml
```

**Protobuf and Avro are deliberately not names.** Each needs something a string
cannot carry — a generated message class, a schema, a registry — so each is built and
handed over in `codec`. The sections below are that.

`rexml` has not been a default gem since Ruby 3.4, so `format: xml` needs
`gem "rexml"` in the Gemfile. The library requires it lazily and names it when it is
missing, which is a clearer failure than a `NameError` but still a failure at the
first message rather than at boot.

## Which codec decodes an incoming message

The AMQP `content-type` property, and nothing else. Not a header, not the message
type, not the queue.

That matters for a queue two services publish to. `JSONCodec` reads anything
claiming JSON *and* anything with no content type at all, which covers a publisher
that did not set one — a `rabbitmqadmin publish` by hand, or another library being
casual. `BytesCodec` is the other one that accepts untyped messages; every other
codec refuses what it does not recognise, and a refusal is a `DecodeError`, which the
retry ladder treats as a failed handler.

## Several formats on one queue

`CompositeCodec` writes with the first and reads with whichever claims the content
type:

```ruby
config.acemq.codec = AceMQ::AMQP::CompositeCodec.new(
  AceMQ::AMQP::JSONCodec.new,                          # what this application writes
  AceMQ::AMQP::YAMLCodec.new,                          # what the legacy publisher writes
  AceMQ::AMQP::XMLCodec.new(root: "order")             # what the bank sends
)
```

The **first codec writes**, always. Order is the interface.

A message none of them will decode raises `DecodeError` naming every candidate it
tried, which is the error message you want when a fourth publisher appears.

This is also the shape of a migration: add the new codec second, deploy it
everywhere, then move it first. Both directions are live for as long as the old
publishers exist, and neither step needs a flag day.

## One message in a different format

`codec:` on a publish, for the one endpoint that wants something else:

```ruby
AceMQ::Rails.publish(order.as_json, to: "order.placed", exchange: "shop-events",
                     codec: AceMQ::AMQP::XMLCodec.new(root: "order"))
```

And on a consumer class, for a queue whose publisher is not this application:

```ruby
class BankFileConsumer < AceMQ::Rails::Consumer
  queue "shop.bank.files"
  codec AceMQ::AMQP::XMLCodec.new(root: "statement")
end
```

`codec` on a consumer class is checked with `AceMQ::AMQP::Codec.check!`, so an object
missing one of `content_type`, `encode`, `decode` and `can_decode?` is refused when
the class is loaded rather than when a message arrives.

## Options worth knowing

```ruby
AceMQ::AMQP::JSONCodec.new(symbolize_names: false)   # the default
```

**Leave it false.** `message.payload["order_id"]` is the shape every example on this
site uses, and it is the shape a payload from another language arrives in. Symbol
keys are a Rails habit that does not survive the wire — and a codec that symbolises
keys from an untrusted publisher is a codec interning arbitrary strings.

```ruby
AceMQ::AMQP::YAMLCodec.new(permitted_classes: [], aliases: false)
```

`Psych.safe_load` underneath, with `Date`, `Time` and `DateTime` always permitted.
Adding to `permitted_classes` is adding to what a publisher can make this process
instantiate, so add what you must and no more. This is the same argument
[not-activejob.md](not-activejob.md) makes about `constantize` on a class name off
the wire, one layer down.

```ruby
AceMQ::AMQP::XMLCodec.new(root: "message")
```

The root element's name, validated against `/\A[A-Za-z_][\w.-]*\z/`.

## Protobuf

One codec per message type, because the class is fixed at construction and nothing on
the wire names it:

```ruby
# Gemfile
gem "google-protobuf", "~> 4.29"
```

```ruby
# config/initializers/acemq.rb
require "acemq/amqp/codec/protobuf"
require Rails.root.join("lib/protos/reading_pb")   # whatever protoc generated

Rails.application.config.acemq.codec = AceMQ::AMQP::ProtobufCodec.new(Shop::Reading)
```

Content type `application/x-protobuf`; it also reads `application/protobuf`,
`application/vnd.google.protobuf` and `…+protobuf`.

`decode` takes only the body — it does not need the content type, because the class
was decided when the codec was built. So a queue carrying two message types needs a
`CompositeCodec` of two `ProtobufCodec`s, and since they both claim the same content
type, the first one to answer wins. In practice that means one type per queue, which
is the shape a protobuf contract wants anyway.

The generated class must be a `Google::Protobuf::MessageExts`; anything else raises
at construction.

## Avro, and schema evolution

Two forms, and the difference is the whole point.

```ruby
# Gemfile
gem "avro", "~> 1.12"
```

**Fixed schema** — reads exactly what it writes. Content type `avro/binary`:

```ruby
AceMQ::AMQP::AvroCodec.of(schema)
```

**Registered** — a schema id travels in the frame, and every message is resolved onto
*this* consumer's schema whatever version wrote it. Content type
`application/vnd.acemq.avro`:

```ruby
AceMQ::AMQP::AvroCodec.registered(registry, subject: "order.placed", schema: WRITER_SCHEMA)
```

The registered form is what lets two services run two versions of one schema and
talk to each other anyway, which is the case worth the trouble. Ruby is always in the
"resolves" column here: `registered` has a reader schema whether or not you pass
`reader_schema:`, because `schema:` serves as both when it is left out.

```ruby
# The consumer reads onto its own schema and lets the producers be ahead of it.
AceMQ::AMQP::AvroCodec.registered(registry, subject: "order.placed",
                                  schema: WRITER_SCHEMA, reader_schema: READER_SCHEMA)
```

Passing `reader_schema:` to `AvroCodec.of` raises — there is no writer's schema there
to resolve against.

The framing is Confluent's: a zero byte, four bytes of big-endian schema id, then the
Avro body.

### The registry, in Rails

`AceMQ::AMQP::Patterns::InMemorySchemaRegistry` is for tests — the ids do not survive
a restart, and an id that changed is a message nothing can decode.

`Patterns::SQLSchemaRegistry` is the durable one, and it has the same
`raw_connection` problem on SQLite that [outbox.md](outbox.md#the-store) describes.
It also needs a **second table**: a companion `acemq_schema_registry_seq` holding the
id counter, seeded with one row. Omit it from a hand-written migration and `register`
raises `FatalError` after five attempts at a race it cannot win.

```ruby
# db/migrate/20260926000200_create_acemq_schema_registry.rb
class CreateAcemqSchemaRegistry < ActiveRecord::Migration[7.1]
  def change
    create_table :acemq_schema_registry, id: false do |t|
      t.integer  :id,             null: false, primary_key: true
      t.string   :subject,        null: false, limit: 255
      t.integer  :schema_version, null: false
      t.string   :format,         null: false, limit: 32
      t.text     :definition,     null: false
      t.string   :fingerprint,    null: false, limit: 64
      t.datetime :registered_at,  null: false
    end
    add_index :acemq_schema_registry, %i[subject fingerprint], unique: true,
                                      name: "acemq_schema_registry_fingerprint"

    create_table :acemq_schema_registry_seq, id: false do |t|
      t.integer :only_row, null: false, primary_key: true
      t.integer :last_id,  null: false
    end
    reversible { |dir| dir.up { execute "INSERT INTO acemq_schema_registry_seq (only_row, last_id) VALUES (1, 0)" } }
  end
end
```

The registry interface is three reads and one write — `register(subject, format,
definition)`, `by_id(id)`, `latest(subject)`, `versions(subject)` — so an
ActiveRecord-backed one is as short as the outbox store and works on every database.
The one rule it must keep is the one the unique index expresses: the same definition
registered twice is the same id, because the id is what travels in the frame.

Nothing in a registry touches the wire. The framing is the codec's, which is why a
registry is useless on its own and always appears beside `AvroCodec.registered`.

## Encrypted and claim-checked payloads

Both are codecs wrapping a codec, so both go in `config.acemq.codec` and neither
needs a new setting:

```ruby
# Encrypted — see security.md
AceMQ::AMQP::EncryptedCodec.wrapping(AceMQ::AMQP::JSONCodec.new, keyring)

# Claim-checked — see patterns.md
AceMQ::AMQP::Patterns::ClaimCheckCodec.wrapping(AceMQ::AMQP::JSONCodec.new, store)
```

They compose, in that order or the other, and the order decides what the store holds:
encrypt-then-check puts ciphertext in the store, check-then-encrypt puts a key in the
message and plaintext in the store. Almost always the first.

## Writing one

Four methods, no base class, checked by duck type:

```ruby
# app/models/csv_codec.rb
class CsvCodec
  def content_type = "text/csv"

  def encode(payload) = CSV.generate { |csv| payload.each { |row| csv << row } }

  # One argument or two. Two gets the incoming content type, which a codec only
  # needs if it decodes more than one thing.
  def decode(body) = CSV.parse(body)

  def can_decode?(content_type) = content_type.to_s.start_with?("text/csv")
end
```

`AceMQ::AMQP::Codec.check!(candidate)` is what `config.acemq.codec` and a consumer
class's `codec` both run it through, so a missing method is a boot failure naming
what is missing.

Two things a codec must not do, both learned the hard way in this family of
libraries: it must not be stateful (one instance serves every thread on the
connection), and `can_decode?` must not answer true for an empty content type unless
it genuinely can read anything — that is how an untyped message from a stray
publisher ends up parsed as the wrong format and accepted.

## Registering a name

`Codecs.register(name, &build)`, where the block builds a **new** codec each time:

```ruby
# config/initializers/acemq.rb
AceMQ::AMQP::Codecs.register("csv") { CsvCodec.new }
```

```yaml
shared:
  format: csv
```

Worth it only when the name has to appear in YAML — a different format per
environment, say. Otherwise `config.acemq.codec` is one line and needs no registry.

## Testing

A codec is a pair of pure functions, so test it as one and do not involve a broker:

```ruby
RSpec.describe CsvCodec do
  it "round-trips" do
    expect(described_class.new.decode(described_class.new.encode([%w[a b]]))).to eq([%w[a b]])
  end

  it "refuses what it cannot read" do
    expect(described_class.new.can_decode?("application/json")).to be(false)
  end
end
```

And for the thing that actually breaks — a consumer meeting a payload from the other
service — publish the real bytes through a fake transport and let the codec decide.
[testing.md](testing.md).

## See also

- [Configuration](configuration.md) — `format` and `codec`
- [Security](security.md) — `EncryptedCodec`
- [Patterns](patterns.md) — `ClaimCheckCodec`, and the schema registry
- [The library's serialization page](https://acemq.org/acemq-ruby-amqp/serialization.html)
