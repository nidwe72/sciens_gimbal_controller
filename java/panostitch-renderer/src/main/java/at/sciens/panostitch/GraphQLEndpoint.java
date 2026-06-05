package at.sciens.panostitch;

import com.fasterxml.jackson.databind.ObjectMapper;
import graphql.ExecutionInput;
import graphql.ExecutionResult;
import graphql.GraphQL;
import graphql.execution.SubscriptionExecutionStrategy;
import graphql.schema.GraphQLSchema;
import graphql.schema.idl.RuntimeWiring;
import graphql.schema.idl.SchemaGenerator;
import graphql.schema.idl.SchemaParser;
import graphql.schema.idl.TypeDefinitionRegistry;
import io.javalin.Javalin;
import io.javalin.http.Context;
import io.javalin.http.HttpStatus;

import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

/**
 * Wires the GraphQL schema + resolvers into Javalin, plus the paired
 * {@code POST /upload} (one tile per call) and {@code GET /result/{stitchId}}
 * (the stitched PNG) endpoints. Adapted from petzvalStudio's GraphQLEndpoint,
 * slimmed to the stitch surface.
 */
public final class GraphQLEndpoint {

    private static final String VERSION = "panostitch-renderer 0.1.0";

    private final GraphQL graphQL;
    private final ObjectMapper json = new ObjectMapper();
    private final StitchService service;

    public GraphQLEndpoint(StitchEngine engine) {
        this.service = new StitchService(engine);
        TypeDefinitionRegistry typeRegistry = loadSchema();
        RuntimeWiring wiring = RuntimeWiring.newRuntimeWiring()
                .type("Query", b -> b
                        .dataFetcher("version", env -> VERSION))
                .type("Mutation", b -> b
                        .dataFetcher("stitch", env -> {
                            List<String> uploadIds = env.getArgument("uploadIds");
                            Object nColsArg = env.getArgument("nCols");
                            int nCols = nColsArg instanceof Number ? ((Number) nColsArg).intValue() : 0;
                            return service.stitch(uploadIds, nCols);
                        })
                        .dataFetcher("cancel", env ->
                                service.cancel(env.getArgument("stitchId"))))
                .type("Subscription", b -> b
                        .dataFetcher("stitchEvents", env ->
                                service.eventPublisher(env.getArgument("stitchId"))))
                .build();
        GraphQLSchema schema = new SchemaGenerator()
                .makeExecutableSchema(typeRegistry, wiring);
        // Subscriptions REQUIRE the SubscriptionExecutionStrategy — the default
        // does not return a Publisher, so stitchEvents would never stream.
        this.graphQL = GraphQL.newGraphQL(schema)
                .subscriptionExecutionStrategy(new SubscriptionExecutionStrategy())
                .build();
    }

    public void register(Javalin app) {
        app.post("/graphql", this::handle);
        app.post("/upload", this::handleUpload);
        app.get("/result/{stitchId}", this::handleResult);
        GraphQLWsHandler wsHandler = new GraphQLWsHandler(graphQL, json);
        app.ws("/graphql-ws", wsHandler::configure);
    }

    private void handleUpload(Context ctx) {
        byte[] bytes = ctx.bodyAsBytes();
        if (bytes.length == 0) {
            ctx.status(HttpStatus.BAD_REQUEST).result("empty body");
            return;
        }
        String uploadId = service.registerUpload(bytes);
        ctx.contentType("application/json");
        ctx.result("{\"uploadId\":\"" + uploadId + "\"}");
    }

    private void handleResult(Context ctx) {
        String stitchId = ctx.pathParam("stitchId");
        StitchService.Result r = service.fetchResult(stitchId);
        if (r == null) {
            ctx.status(HttpStatus.NOT_FOUND).result("no result for stitchId=" + stitchId);
            return;
        }
        switch (r.status) {
            case OK -> {
                ctx.contentType("image/png");
                ctx.header("X-Pano-Width", String.valueOf(r.width));
                ctx.header("X-Pano-Height", String.valueOf(r.height));
                ctx.result(r.png);
            }
            case CANCELLED -> ctx.status(HttpStatus.GONE).result("cancelled");
            case FAILED -> ctx.status(HttpStatus.INTERNAL_SERVER_ERROR).result(r.error);
        }
    }

    @SuppressWarnings("unchecked")
    private void handle(Context ctx) throws Exception {
        Map<String, Object> body = json.readValue(ctx.bodyAsBytes(), Map.class);
        String query = (String) body.get("query");
        Map<String, Object> variables = (Map<String, Object>) body.getOrDefault("variables", Map.of());
        String operationName = (String) body.get("operationName");

        ExecutionInput input = ExecutionInput.newExecutionInput()
                .query(query)
                .variables(variables)
                .operationName(operationName)
                .build();

        ExecutionResult result = graphQL.execute(input);
        ctx.contentType("application/json");
        ctx.result(json.writeValueAsBytes(result.toSpecification()));
    }

    private static TypeDefinitionRegistry loadSchema() {
        try (InputStream in = GraphQLEndpoint.class.getResourceAsStream("/schema.graphqls")) {
            if (in == null) {
                throw new IllegalStateException("schema.graphqls missing from classpath");
            }
            String sdl = new String(in.readAllBytes(), StandardCharsets.UTF_8);
            return new SchemaParser().parse(sdl);
        } catch (Exception e) {
            throw new RuntimeException("Failed to load schema.graphqls", e);
        }
    }
}
