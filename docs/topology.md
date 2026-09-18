# Topology

The exchanges, queues and bindings this application needs, declared in
`config/acemq.yml` and applied by a rake task.

```yaml
topology:
  exchanges:
    - { name: shop-events, type: topic }
  queues:
    - name: shop.orders
      dead_letter: true
      retries:
        max_attempts: 5
        initial_delay: 10
        max_delay: 300
        broker_wait_threshold: 10
  bindings:
    - { queue: shop.orders, exchange: shop-events, routing_key: "order.#" }
```

```bash
bin/rails acemq:topology
```

Prints the plan and applies it. Idempotent, so it belongs in a deploy step beside
`db:migrate`. The consumer process applies it on boot too, which covers a
development machine; `declare_topology_on_boot: false` turns that off for an
estate where a deployment tool owns the broker.

## Declared, not inferred

Nothing is created because a consumer class mentioned a queue name. A queue that
appears that way is a queue whose durability, type and dead-lettering nobody
decided — and all three are part of a queue's identity to the broker. Get them
wrong once and the second service to declare it is refused with
`PRECONDITION_FAILED` and cannot consume at all.

## Queues

| Key | Default | |
|---|---|---|
| `name` | required | |
| `type` | `quorum` | `classic`, `quorum` or `stream` |
| `durable` | `true` | |
| `auto_delete`, `exclusive` | `false` | Either one forces `classic`; RabbitMQ allows nothing else |
| `dead_letter` | `false` | Declares `{name}.dlq` and the exchange that reaches it |
| `retries` | — | Declares the rung queues a ladder needs |
| `arguments` | `{}` | Anything else, `x-max-length` and friends |

**Quorum by default**, which is the same default as the Java library's
`declareQueue`, and the reason is interop rather than taste: `x-queue-type` is
part of a queue's identity, so two services sharing `shop.orders` have to declare
the same kind or the second is refused.

**`dead_letter: true` means `{name}.dlq`** and there is deliberately no way to
name a different queue. The name comes from `Naming.dead_letter_queue` in all five
libraries; a Ruby service that renamed its own would be draining a queue the Java
service beside it has never heard of.

## Retry rungs

`retries:` on a queue declares the rung queues its ladder needs — one per delay
at or above `broker_wait_threshold`, each an `x-message-ttl` that dead-letters
home.

Declaring them is not optional in any practical sense. A consumer that cannot
find its rung still retries, waiting in this process instead, which holds a
prefetch slot and makes the next deployment's drain sit through the wait. The
library counts `acemq.retry.rung.missing` every time. See
[lifecycle.md](lifecycle.md).

The ladder here and the consumer's own `retries` should match. A consumer
configured with a threshold the topology did not declare rungs for is a consumer
looking for queues nobody made.

## Exchanges and bindings

```yaml
exchanges:
  - { name: shop-events, type: topic }     # direct, topic, fanout, headers
bindings:
  - { queue: shop.orders, exchange: shop-events, routing_key: "order.#" }
```

`routing_key` is ignored by a fanout and required in practice by a direct or a
topic.

## Checking it without applying it

```ruby
puts AceMQ::Rails.topology.plan      # every declaration, in order
puts AceMQ::Rails.topology.problems  # anything that cannot stand up
```

`problems` catches a binding to a queue nothing declares, a duplicate name, an
exchange with no kind — the mistakes that otherwise appear as a message routed
nowhere.
