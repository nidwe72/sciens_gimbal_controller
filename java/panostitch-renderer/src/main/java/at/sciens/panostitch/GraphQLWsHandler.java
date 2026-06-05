package at.sciens.panostitch;

import com.fasterxml.jackson.databind.ObjectMapper;
import graphql.ExecutionInput;
import graphql.ExecutionResult;
import graphql.GraphQL;
import io.javalin.websocket.WsConfig;
import io.javalin.websocket.WsContext;
import io.javalin.websocket.WsMessageContext;
import org.reactivestreams.Publisher;
import org.reactivestreams.Subscriber;
import org.reactivestreams.Subscription;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Render/stitch progress over WebSocket, speaking the {@code
 * graphql-transport-ws} message shape ({@code connection_init}/{@code
 * connection_ack} → {@code subscribe} → {@code next}* → {@code complete}) over a
 * plain Javalin WebSocket. Forked verbatim from petzvalStudio's GraphQLWsHandler
 * — it is operation-agnostic, so nothing changes but the package.
 */
final class GraphQLWsHandler {

    private static final Logger LOG = LoggerFactory.getLogger(GraphQLWsHandler.class);

    private final GraphQL graphQL;
    private final ObjectMapper json;

    private final Map<String, Session> sessions = new ConcurrentHashMap<>();

    GraphQLWsHandler(GraphQL graphQL, ObjectMapper json) {
        this.graphQL = graphQL;
        this.json = json;
    }

    private static final class Session {
        final Object sendLock = new Object();
        final Map<String, Subscription> ops = new ConcurrentHashMap<>();
    }

    void configure(WsConfig ws) {
        ws.onConnect(ctx -> sessions.put(ctx.sessionId(), new Session()));
        ws.onClose(ctx -> closeSession(ctx.sessionId()));
        ws.onError(ctx -> closeSession(ctx.sessionId()));
        ws.onMessage(ctx -> {
            try {
                onMessage(ctx);
            } catch (Exception e) {
                LOG.debug("ws message handling failed: {}", e.toString());
            }
        });
    }

    @SuppressWarnings("unchecked")
    private void onMessage(WsMessageContext ctx) throws Exception {
        Session session = sessions.computeIfAbsent(ctx.sessionId(), k -> new Session());
        Map<String, Object> m = json.readValue(ctx.message(), Map.class);
        String type = String.valueOf(m.get("type"));
        switch (type) {
            case "connection_init" -> send(ctx, session, Map.of("type", "connection_ack"));
            case "ping" -> send(ctx, session, Map.of("type", "pong"));
            case "pong" -> { /* no-op */ }
            case "subscribe" -> subscribe(ctx, session, m);
            case "complete" -> {
                Subscription s = session.ops.remove(String.valueOf(m.get("id")));
                if (s != null) s.cancel();
            }
            default -> LOG.debug("ws: ignoring message type {}", type);
        }
    }

    @SuppressWarnings("unchecked")
    private void subscribe(WsContext ctx, Session session, Map<String, Object> m) {
        String opId = String.valueOf(m.get("id"));
        Map<String, Object> payload = m.get("payload") instanceof Map
                ? (Map<String, Object>) m.get("payload") : Map.of();
        String query = (String) payload.get("query");
        Map<String, Object> variables = payload.get("variables") instanceof Map
                ? (Map<String, Object>) payload.get("variables") : Map.of();

        ExecutionInput input = ExecutionInput.newExecutionInput(query)
                .variables(variables)
                .build();
        ExecutionResult exec = graphQL.execute(input);
        Object data = exec.getData();
        if (!(data instanceof Publisher)) {
            send(ctx, session, Map.of("id", opId, "type", "error",
                    "payload", errorPayload(exec)));
            return;
        }

        Publisher<ExecutionResult> stream = (Publisher<ExecutionResult>) data;
        stream.subscribe(new Subscriber<>() {
            @Override public void onSubscribe(Subscription s) {
                session.ops.put(opId, s);
                s.request(Long.MAX_VALUE);
            }
            @Override public void onNext(ExecutionResult er) {
                send(ctx, session, Map.of("id", opId, "type", "next",
                        "payload", er.toSpecification()));
            }
            @Override public void onError(Throwable t) {
                LOG.warn("ws subscription op={} error: {}", opId, t.toString());
                send(ctx, session, Map.of("id", opId, "type", "error",
                        "payload", List.of(Map.of("message",
                                String.valueOf(t.getMessage())))));
                session.ops.remove(opId);
            }
            @Override public void onComplete() {
                send(ctx, session, Map.of("id", opId, "type", "complete"));
                session.ops.remove(opId);
            }
        });
    }

    private static List<Object> errorPayload(ExecutionResult exec) {
        if (exec.getErrors() == null || exec.getErrors().isEmpty()) {
            return List.of(Map.of("message", "subscription did not produce a stream"));
        }
        return exec.getErrors().stream().map(e -> (Object) e.toSpecification()).toList();
    }

    private void closeSession(String sessionId) {
        Session session = sessions.remove(sessionId);
        if (session == null) return;
        for (Subscription s : session.ops.values()) {
            try { s.cancel(); } catch (RuntimeException ignored) { /* shutting down */ }
        }
        session.ops.clear();
    }

    private void send(WsContext ctx, Session session, Map<String, Object> msg) {
        try {
            String s = json.writeValueAsString(msg);
            synchronized (session.sendLock) {
                ctx.send(s);
            }
        } catch (Exception e) {
            LOG.debug("ws send failed: {}", e.toString());
        }
    }
}
