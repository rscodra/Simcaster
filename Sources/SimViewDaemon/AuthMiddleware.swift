import Hummingbird

struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let token: String
    let sessionStore: SessionStore

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let queryToken = request.uri.queryParameters["token"].map(String.init)

        // Master token — full access
        if queryToken == token {
            return try await next(request, context)
        }
        if let auth = request.headers[.authorization], auth == "Bearer \(token)" {
            return try await next(request, context)
        }

        // Viewer token — scoped to a single session's viewer, WebSocket, and input routes
        let path = request.uri.path
        if let queryToken,
           (path.hasPrefix("/sessions/") || path.hasPrefix("/ws/sessions/") || path.hasPrefix("/api/sessions/")) {
            let parts = path.split(separator: "/")
            if let sessIdx = parts.firstIndex(where: { $0.hasPrefix("sess_") }),
               let session = sessionStore.get(String(parts[sessIdx])),
               session.viewerToken == queryToken {
                return try await next(request, context)
            }
        }

        return Response(status: .unauthorized, body: .init(byteBuffer: ByteBuffer(string: "Unauthorized")))
    }
}
