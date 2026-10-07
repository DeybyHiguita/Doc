# 📝 Puntos Dorados — Cambios en el frontend (refactorización del 7 oct 2026)

Registro de cómo quedó implementada la conexión de **reconocimientos** en DOCCB-frontend, y del patrón que sale de ahí para conectar las próximas funciones a la API (puntos, redención).

> **Fuente:** el resumen de cambios del equipo. No reemplaza al código: los nombres exactos (métodos de `AuthService`, de `HttpErrorHandlerService`, firma de `runRecognitionRequest`) se confirman en los archivos. Las guías anteriores no se modificaron; las diferencias con ellas están en la sección 5.

---

## 1. `golden-recognitions.service.ts` — servicio de API

### Qué cambió

| Antes (guía) | Ahora (código) |
|---|---|
| `HttpClient` sin encabezados: se suponía un interceptor que agrega el token. | **Autenticación explícita:** se inyecta `AuthService` y cada método obtiene los encabezados con `await this.authHeaders()` antes de la petición. |
| Métodos que devuelven `Observable<GoldenResult<T>>`. | Métodos `async` que devuelven **`Promise<Observable<GoldenResult<T>>>`**: primero esperan el token y luego arman la petición. |
| Errores HTTP sin tratar en el servicio. | **`catchError`** en cada petición, que delega en `HttpErrorHandlerService`. |
| URL base importada directamente. | `environment.api.baseUrl`. |

### Forma general

```ts
@Injectable({ providedIn: 'root' })
export class GoldenRecognitionsService {
  private readonly http = inject(HttpClient);
  private readonly authService = inject(AuthService);
  private readonly httpErrorHandler = inject(HttpErrorHandlerService);
  private readonly baseUrl = `${environment.api.baseUrl}/api/GoldenRecognitions`;

  async getFeed(page: number, pageSize: number, categoryId?: number | null): Promise<Observable<GoldenResult<GoldenPagedResult<GoldenFeedItem>>>> {
    const headers = await this.authHeaders();

    return this.http
      .get<GoldenResultDto<GoldenPagedResultDto<GoldenFeedItemDto>>>(`${this.baseUrl}/feed`, { headers, params: /* … */ })
      .pipe(
        map(dto => toResult(dto, page => toPage(page, toFeedItem))),
        catchError(error => /* HttpErrorHandlerService: método real del proyecto */ this.httpErrorHandler.handle(error)),
      );
  }

  // getSent, getReceived, create, getReactions, addReaction, removeReaction: mismo patrón.

  private async authHeaders(): Promise<HttpHeaders> {
    // Usa AuthService para obtener el token de acceso y arma { Authorization: `Bearer …` }.
  }
}
```

---

## 2. `puntos-dorados.facade.ts` — facade

### Qué cambió

| Antes (guía) | Ahora (código) |
|---|---|
| Helper privado `toPromise(observable, fallback)`. | Helper privado **`runRecognitionRequest(...)`**: resuelve la promesa del servicio y el observable, y **atrapa cualquier error** devolviendo `{ hasError: true, response: null, errors: [...] }`. |
| Llamadas con `.toPromise()` en varios métodos. | Ya no hay `.toPromise()` sueltos: todo pasa por `runRecognitionRequest`. |
| Facade sin estado. | **Signals de estado** en el facade: `nominationsSignal`, `productsSignal`, `reactionsSignal`, etc. |

### Forma general

```ts
/** Ninguna excepción sale del facade: el componente solo revisa hasError. */
private async runRecognitionRequest<T>(
  request: () => Promise<Observable<GoldenResult<T>>>,
  fallback: string,
): Promise<GoldenResult<T>> {
  try {
    return await firstValueFrom(await request());
  } catch (error) {
    return { hasError: true, response: null, errors: [toErrorMessage(error, fallback)] };
  }
}

getRecognitionFeed(page: number, pageSize: number): Promise<GoldenResult<GoldenPagedResult<GoldenFeedItem>>> {
  return this.runRecognitionRequest(() => this.recognitions.getFeed(page, pageSize), 'No se pudo cargar el feed de reconocimientos.');
}
```

> Firma aproximada: confirma en el código si `runRecognitionRequest` recibe una función o la promesa directamente.

---

## 3. `puntos-dorados-user.component.ts` — colaborador

### Signals

El estado de la vista pasó a signals: `userName`, `userEmail`, `userRole`, `permissions`, `activeTab`, `showPostularModal`, etc.

### Carga por pestaña

| Antes | Ahora |
|---|---|
| `loadModuleData()` hacía un `Promise.all` con personas, nominaciones y datos financieros al abrir la pantalla. | `loadModuleData()` carga **solo lo esencial: personas**. |
| Cada pestaña con su propio flag (`recognizeTabLoaded`, `redeemTabLoaded`). | **`loadTabData(tab: UserTab)`** carga los datos de la pestaña visible con `ensureLoaded()`: `this.feed.ensureLoaded()`, `this.sentRecognitions.ensureLoaded()`, etc. |

```ts
private loadTabData(tab: UserTab): void {
  switch (tab) {
    case 'feed':
      void this.feed.ensureLoaded();
      break;
    case 'reconocer':
      void this.sentRecognitions.ensureLoaded();
      // + categorías activas para el modal
      break;
    case 'mis-reconocimientos':
      void this.receivedRecognitions.ensureLoaded();
      break;
    // 'redimir': catálogo disponible
  }
}
```

`setActiveTab(tab)` y la carga inicial llaman a `loadTabData` con la pestaña activa.

### `submitNomination`

1. Toma del formulario `nomineeEmail`, `categoryId` y `reason`. Ya no busca el objeto completo de la persona.
2. **Si la API responde error:** `this.nominationErrors.set(result.errors)`. El modal **sigue abierto** y no se pierde lo escrito.
3. **Si sale bien:** cierra el modal, limpia `submittingNomination` y recarga los enviados con `await this.sentRecognitions.reload()`.

> En el resumen aparece `result.hasError()` con paréntesis. En `GoldenResult` es una **propiedad** (`result.hasError`); verifica que en el código no se esté llamando como función.

---

## 4. Patrón para conectar nuevas funciones a la API

Lo que hay que seguir de aquí en adelante (puntos, redención, aprobaciones):

| Capa | Regla |
|---|---|
| **Servicio** | `async`, `const headers = await this.authHeaders()`, petición con `{ headers }`, `map(dto => toResult(...))` y `catchError` con `HttpErrorHandlerService`. Devuelve `Promise<Observable<GoldenResult<T>>>`. |
| **Facade** | Cada método pasa por el wrapper (`runRecognitionRequest` o su equivalente) y devuelve `Promise<GoldenResult<T>>`. Nunca lanza. |
| **Componente** | Revisa `result.hasError`. Los errores van a un signal (`xxxErrors`) que se muestra donde está el formulario, sin cerrarlo. Los datos de cada pestaña se cargan en `loadTabData`. |

---

## 5. Diferencias con las guías (sin modificarlas)

| Guía | Lo que dice | Cómo quedó / qué ajustar al usarla |
|---|---|---|
| [puntos-dorados-reconocimientos-angular.md](puntos-dorados-reconocimientos-angular.md) | Servicio sin encabezados, métodos `Observable`, facade con `toPromise`, carga por pestaña con `ensureRecognitionTab`. | Implementado con el patrón de la sección 4 y `loadTabData`. |
| [puntos-dorados-puntos-angular.md](puntos-dorados-puntos-angular.md) | `GoldenPointsService` con métodos `Observable` sin `authHeaders`; facade con `this.toPromise(...)`. | Al implementarla: `GoldenPointsService` con el patrón de la sección 4 y los seis métodos del facade con el wrapper. Los componentes `app-golden-points-admin` y `app-my-points` no cambian: solo llaman al facade. |

**Sobre el wrapper:** ahora lo van a usar también puntos y, después, redención. Conviene un nombre genérico (por ejemplo `runApiRequest`) para no llamar `runRecognitionRequest` desde puntos. Es solo un renombre.

---

## 6. Observaciones para revisar

| # | Tema | Por qué importa | Sugerencia |
|---|---|---|---|
| 1 | **Dos mensajes para un mismo error.** | Si `HttpErrorHandlerService` ya muestra una alerta y además el componente muestra `result.errors`, el usuario ve el error dos veces. | Decidir quién lo muestra: el handler para errores generales (red, 401, 500) y el componente para errores de negocio (`hasError` con HTTP 200). |
| 2 | **Qué devuelve el `catchError`.** | Si el handler devuelve `EMPTY`, `firstValueFrom` falla con `EmptyError` y el wrapper responde el mensaje genérico, sin el detalle del servidor. Si relanza el error, el wrapper puede leer el detalle con `toErrorMessage`. | Confirmar que el handler **relance** (`throwError(() => error)`) después de registrar o mostrar. |
| 3 | **`Promise<Observable<T>>`.** | Funciona, pero cada llamada necesita dos `await` (`firstValueFrom(await request())`). | Opcional: `from(this.authHeaders()).pipe(switchMap(headers => this.http.get(..., { headers })))` devuelve un `Observable<T>` simple. Un `HttpInterceptor` (o el de MSAL) quitaría `authHeaders` de cada servicio. |
| 4 | **Estado en el facade y en el componente.** | Con `nominationsSignal` en el facade y listas paginadas en el componente hay dos fuentes de verdad para lo mismo. | Dejar un solo dueño por dato: las listas paginadas (`PagedList`) en el componente; en el facade, solo lo que compartan varias pantallas. |
| 5 | **SSR.** | `loadTabData` en el servidor llamaría a la API sin token. | Confirmar que `loadTabData` (y `authHeaders`) solo se ejecutan en el navegador (`isPlatformBrowser`). |
| 6 | **Token vencido.** | `authHeaders()` debe pedir el token en silencio (`acquireTokenSilent`) en cada llamada, no guardarlo en una variable. | Revisar `AuthService`. |
