# 👁️ Componente de previsualización de PDF sin descarga (Angular 20)

Componente compartido que muestra un PDF **solo para lectura**: sin botón de descargar, sin imprimir y sin abrir archivo. Recibe una **URL** que entrega un servicio, o un `Blob` ya generado en el front.

Vive en `src/app/shared/components/pdf-preview/` porque lo van a usar certificados, solicitudes y cualquier otra feature que necesite mostrar un documento.

- **Stack:** Angular 20 · standalone · signals · OnPush · SSR habilitado · MSAL
- **Renderizador:** `ngx-extended-pdf-viewer`

---

## 1. ⚠️ Lo primero: ocultar el botón no impide descargar

Hay que decirlo antes de escribir una línea, porque cambia qué se le promete al negocio:

**Quitar el botón de descarga es una decisión de interfaz, no un control de seguridad.** Cuando el PDF se renderiza en el navegador, sus bytes ya están en la máquina del usuario: con la pestaña Red de las herramientas de desarrollo, cualquiera lo guarda en dos clics.

| Lo que se pide | Lo que resuelve este componente |
|---|---|
| "Que no haya un botón que invite a descargar" | ✅ Sí. Es exactamente esto. |
| "Que el usuario vea el borrador pero descargue solo el definitivo" | ✅ Sí, como flujo de interfaz. |
| "Que el usuario **no pueda** quedarse con el archivo" | ❌ No. Ningún visor web lo logra. |

Si el requisito real es el tercero, la solución no está en el front:

- marca de agua con el nombre y la cédula de quien previsualiza, aplicada en el backend;
- URL firmada de un solo uso y vida corta (segundos);
- servir la previsualización como **imágenes** por página, no como PDF;
- registrar en auditoría cada previsualización.

Cualquiera de esas tres primeras se hace en el backend. Lo que sigue en este documento resuelve el caso de interfaz, que es el que casi siempre se está pidiendo.

---

## 2. 📦 Instalación

```bash
npm install ngx-extended-pdf-viewer
```

**Verifica la versión compatible con Angular 20 antes de instalar** — la librería sube un major por cada versión de Angular:

```bash
npm info ngx-extended-pdf-viewer peerDependencies
```

Registra los assets de pdf.js en `angular.json`, dentro de `projects.<app>.architect.build.options.assets`:

```json
{
  "glob": "**/*",
  "input": "node_modules/ngx-extended-pdf-viewer/assets/",
  "output": "/assets/"
}
```

> La ruta de los assets cambió entre versiones. Si al abrir un PDF ves 404 de `pdf.worker` o de los `.properties` de idioma, revisa el README de la versión instalada: es el único paso de configuración que suele fallar.

---

## 3. 📁 Archivos

```text
src/app/shared/
├── components/
│   └── pdf-preview/
│       ├── pdf-preview.component.ts          ⭐ el componente
│       ├── pdf-preview.component.html
│       └── pdf-preview.component.scss
└── services/
    └── pdf-source.service.ts                 ⭐ URL → Blob (con token MSAL)
```

---

## 4. 🔑 El servicio: por qué la URL no va directa al visor

Este es el punto que más tiempo hace perder si se descubre tarde.

Tu `app.config.ts` registra el interceptor de MSAL con:

```ts
protectedResourceMap = new Map([
  ['/api/', environment.api.apiScopes],
]);
```

Ese interceptor solo actúa sobre peticiones de **`HttpClient`**. Un `<iframe src>`, un `<embed>` o el `[src]="'https://.../api/...'"` del visor hacen la petición **por fuera de Angular**: no llevan el `Authorization: Bearer`, y la API responde **401**. El visor entonces muestra un error genérico de "archivo corrupto" y uno termina buscando el problema en el PDF, que está perfecto.

**La regla:** si la URL está protegida, se descarga con `HttpClient` y se le pasa el `Blob` al visor.

### `shared/services/pdf-source.service.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';
import { Observable, map, catchError, throwError } from 'rxjs';

const PDF_MIME = 'application/pdf';

@Injectable({ providedIn: 'root' })
export class PdfSourceService {
  private readonly http = inject(HttpClient);

  /**
   * Descarga el PDF pasando por HttpClient para que el interceptor de MSAL
   * adjunte el token. Devuelve el Blob listo para el visor.
   */
  fromUrl(url: string): Observable<Blob> {
    return this.http.get(url, { responseType: 'blob' }).pipe(
      map((blob) => this.assertPdf(blob)),
      catchError((error) => throwError(() => this.toFriendlyError(error))),
    );
  }

  /** Cuando la API responde el envelope estándar con el PDF en base64. */
  fromBase64(base64: string): Blob {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      bytes[i] = binary.charCodeAt(i);
    }
    return new Blob([bytes], { type: PDF_MIME });
  }

  /**
   * Una sesión vencida o un gateway intermedio pueden responder 200 con HTML.
   * Sin esta guarda, el visor falla con un mensaje que no dice nada útil.
   */
  private assertPdf(blob: Blob): Blob {
    if (blob.type && !blob.type.includes('pdf')) {
      throw new Error('La respuesta del servidor no es un PDF. Vuelve a iniciar sesión e inténtalo de nuevo.');
    }
    return blob;
  }

  private toFriendlyError(error: unknown): Error {
    const status = (error as { status?: number })?.status;

    if (status === 401 || status === 403) {
      return new Error('No tienes permiso para ver este documento.');
    }
    if (status === 404) {
      return new Error('El documento no existe o ya no está disponible.');
    }
    return new Error('No se pudo cargar el documento. Inténtalo de nuevo.');
  }
}
```

> Si la URL es pública (un asset del propio dominio o un CDN sin autenticación), puedes pasarla tal cual al visor y saltarte el servicio. En ese caso el componente acepta `string` y la reenvía sin descargarla.

---

## 5. 🧩 El componente

### API pública

| Entrada | Tipo | Para qué |
|---|---|---|
| `src` | `string \| Blob \| null` | URL protegida, URL pública o `Blob` ya generado. |
| `fileName` | `string` | Solo para el `aria-label` y el título accesible. |
| `height` | `string` | Alto del lienzo. Por defecto `'75vh'`. |
| `allowPrint` | `boolean` | `false` por defecto. Déjalo en `false` salvo que el negocio lo pida. |
| `zoom` | `string` | `'page-width'` por defecto. |

| Salida | Cuándo |
|---|---|
| `loaded` | El documento terminó de renderizar. |
| `failed` | Falló la descarga o el renderizado. |

### `pdf-preview.component.ts`

```ts
import {
  ChangeDetectionStrategy,
  Component,
  computed,
  effect,
  inject,
  input,
  output,
  resource,
  signal,
  PLATFORM_ID,
} from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { firstValueFrom } from 'rxjs';
import { NgxExtendedPdfViewerModule } from 'ngx-extended-pdf-viewer';
import { PdfSourceService } from '@shared/services/pdf-source.service';

@Component({
  selector: 'app-pdf-preview',
  imports: [NgxExtendedPdfViewerModule],
  templateUrl: './pdf-preview.component.html',
  styleUrl: './pdf-preview.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class PdfPreviewComponent {
  private readonly pdfSource = inject(PdfSourceService);
  private readonly platformId = inject(PLATFORM_ID);

  readonly src = input<string | Blob | null>(null);
  readonly fileName = input<string>('documento.pdf');
  readonly height = input<string>('75vh');
  readonly allowPrint = input<boolean>(false);
  readonly zoom = input<string>('page-width');

  readonly loaded = output<void>();
  readonly failed = output<Error>();

  readonly isBrowser = isPlatformBrowser(this.platformId);

  /** Resuelve la fuente: si es URL protegida la descarga; si ya es Blob la deja pasar. */
  readonly documentResource = resource({
    params: () => ({ src: this.src() }),
    loader: async ({ params }) => {
      if (!params.src || !this.isBrowser) return null;
      if (params.src instanceof Blob) return params.src;
      return firstValueFrom(this.pdfSource.fromUrl(params.src));
    },
  });

  readonly document = computed(() => this.documentResource.value() ?? null);
  readonly isLoading = computed(() => this.documentResource.isLoading() || this.isRendering());
  readonly error = computed(
    () => (this.documentResource.error() as Error | undefined) ?? this.renderError(),
  );

  /** El visor tarda en pintar después de tener los bytes: hay dos etapas de carga. */
  private readonly isRendering = signal(false);
  private readonly renderError = signal<Error | null>(null);

  constructor() {
    effect(() => {
      if (this.document()) {
        this.isRendering.set(true);
        this.renderError.set(null);
      }
    });
  }

  onPdfLoaded(): void {
    this.isRendering.set(false);
    this.loaded.emit();
  }

  onPdfFailed(error: unknown): void {
    this.isRendering.set(false);
    const failure = error instanceof Error ? error : new Error('No se pudo mostrar el documento.');
    this.renderError.set(failure);
    this.failed.emit(failure);
  }

  reload(): void {
    this.renderError.set(null);
    this.documentResource.reload();
  }
}
```

> **`resource()` es experimental en Angular 20.** Si tu versión usa la firma anterior, renombra `params:` por `request:`. El equivalente estable es `toSignal` sobre el observable del servicio.

### `pdf-preview.component.html`

Los inputs en `false` son el corazón del requisito. Léelos como una lista de lo que el usuario **no** va a ver.

```html
<div
  class="pdf-preview"
  [style.height]="height()"
  role="document"
  [attr.aria-label]="'Previsualización de ' + fileName()"
  [attr.aria-busy]="isLoading()">

  @if (!isBrowser) {
    <div class="pdf-preview__state text-muted">
      <p class="mb-0">La previsualización se carga en el navegador.</p>
    </div>
  } @else if (error(); as failure) {
    <div class="pdf-preview__state">
      <div class="alert alert-danger text-center mb-0" role="alert">
        <i class="fa-solid fa-triangle-exclamation fa-lg mb-2" aria-hidden="true"></i>
        <p class="mb-3">{{ failure.message }}</p>
        <button type="button" class="btn btn-outline-danger btn-sm" (click)="reload()">
          Reintentar
        </button>
      </div>
    </div>
  } @else {
    @if (isLoading()) {
      <div class="pdf-preview__overlay">
        <div class="spinner-border" role="status">
          <span class="visually-hidden">Cargando documento…</span>
        </div>
      </div>
    }

    @if (document(); as source) {
      <ngx-extended-pdf-viewer
        [src]="source"
        [height]="height()"
        [zoom]="zoom()"
        [textLayer]="true"

        [showDownloadButton]="false"
        [showOpenFileButton]="false"
        [showPrintButton]="allowPrint()"
        [showSecondaryToolbarButton]="false"
        [showBookmarkButton]="false"
        [showPropertiesButton]="false"
        [contextMenuAllowed]="false"

        [showSidebarButton]="true"
        [showZoomButtons]="true"
        [showPagingButtons]="true"

        (pdfLoaded)="onPdfLoaded()"
        (pdfLoadingFailed)="onPdfFailed($event)" />
    }
  }
</div>
```

**Por qué cada `false`:**

| Input | Razón |
|---|---|
| `showDownloadButton` | El requisito. |
| `showOpenFileButton` | Permite cargar otro PDF dentro de tu visor: no tiene sentido aquí. |
| `showPrintButton` | Imprimir a PDF equivale a descargar. Se abre solo si `allowPrint` lo pide. |
| `showSecondaryToolbarButton` | **El más olvidado.** El menú "⋮" ha incluido, según la versión, "Abrir" y "Guardar": ocultar el botón principal y dejar este menú deja la puerta abierta. |
| `showBookmarkButton` | Genera un enlace directo al archivo. |
| `showPropertiesButton` | Expone la ruta y el nombre original del archivo. |
| `contextMenuAllowed` | Quita "Guardar como…" del clic derecho. |

> Los nombres de los inputs han cambiado entre majors de la librería. Si alguno no compila, búscalo en el README de tu versión: el concepto es el mismo.

### `pdf-preview.component.scss`

```scss
.pdf-preview {
  position: relative;
  width: 100%;
  background-color: var(--bs-gray-200, #e9ecef);
  border-radius: 0.5rem;
  overflow: hidden;

  &__state {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    padding: 2rem;
  }

  &__overlay {
    position: absolute;
    inset: 0;
    z-index: 2;
    display: flex;
    align-items: center;
    justify-content: center;
    background-color: rgb(233 236 239 / 75%);
  }
}
```

---

## 6. 🔌 Cómo se usa

### Caso A — URL que entrega un servicio (el caso que pediste)

```ts
readonly documentUrl = signal<string | null>(null);

verCertificado(id: number): void {
  this.documentUrl.set(`${environment.api.baseUrl}/api/certificados/${id}/pdf`);
}
```

```html
@if (documentUrl(); as url) {
  <app-pdf-preview [src]="url" fileName="certificado.pdf" />
}
```

El componente descarga la URL con `HttpClient` — el token de MSAL viaja — y le entrega el `Blob` al visor.

### Caso B — la API responde el envelope con base64

```ts
this.certificatesService.getPdf(id).subscribe((response) => {
  this.documentBlob.set(this.pdfSource.fromBase64(response.data.base64));
});
```

```html
<app-pdf-preview [src]="documentBlob()" [fileName]="fileName()" />
```

### Caso C — PDF armado en el front con PDFMake

```html
<app-pdf-preview [src]="previewResource.value()?.blob ?? null" />
```

Los tres casos usan el mismo componente: lo único que cambia es de dónde salen los bytes.

---

## 7. 🚀 SSR y peso del bundle

Dos cuidados, los dos obligatorios en este proyecto:

**1. El visor es solo de navegador.** Ya está cubierto con `isPlatformBrowser` y la rama `@if (!isBrowser)` del template.

**2. pdf.js pesa.** No debe entrar al bundle inicial de una pantalla que quizá nadie abra. Envuelve el componente con `@defer` allí donde se use:

```html
@defer (on viewport) {
  <app-pdf-preview [src]="documentUrl()" />
} @placeholder {
  <div class="pdf-preview__skeleton"></div>
} @loading (after 100ms; minimum 300ms) {
  <div class="spinner-border" role="status"></div>
}
```

Con `on viewport` la librería se descarga solo cuando el visor entra en pantalla. En la página de certificados, donde el visor es el contenido principal, usa `@defer (on immediate)`.

---

## 8. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| "Archivo corrupto" o PDF en blanco desde una URL de la API | El visor pidió la URL sin el token de MSAL | Descargar con `HttpClient` y pasar el `Blob`. Es la sección 4. |
| 404 de `pdf.worker.min.js` o de archivos `.properties` | Faltan los assets en `angular.json` | Agregar el bloque de assets de la sección 2. |
| `window is not defined` al compilar o servir con SSR | El visor se instanció en el servidor | `isPlatformBrowser` + `@defer`. |
| El botón de descarga sigue apareciendo | Quedó activo el toolbar secundario | `[showSecondaryToolbarButton]="false"`. |
| El visor se ve con 0 px de alto | `height` sin unidad o contenedor colapsado | Pasar `'75vh'` o `'600px'`, no un número suelto. |
| Cada apertura consume más memoria | Object URLs creadas a mano y nunca revocadas | Pasar el `Blob` directo. Si tu versión no lo acepta, crear la URL en un `effect` y revocarla en su `onCleanup`. |
| El texto no se puede seleccionar | `textLayer` desactivado | `[textLayer]="true"`. Desactívalo solo si quieres dificultar el copiado, sabiendo que también rompe la accesibilidad. |
| Funciona en local y falla en producción | Los assets no se copiaron en el build de producción | Revisar que el bloque de assets esté en la configuración `production`, no solo en `development`. |

---

## 9. ✅ Checklist

- [ ] Al negocio se le explicó que ocultar el botón no impide guardar el archivo.
- [ ] Assets de pdf.js registrados en `angular.json`, en todas las configuraciones de build.
- [ ] Las URLs protegidas pasan por `HttpClient`, nunca directo al `[src]`.
- [ ] `showDownloadButton`, `showOpenFileButton`, `showSecondaryToolbarButton`, `showBookmarkButton` y `showPropertiesButton` en `false`.
- [ ] Clic derecho verificado: no aparece "Guardar como…".
- [ ] Probado con un PDF de varias páginas: paginación y zoom funcionan.
- [ ] Probado el error 401 (sesión vencida): se ve el mensaje amable, no "archivo corrupto".
- [ ] `@defer` aplicado para que pdf.js no entre al bundle inicial.
- [ ] Probado con SSR activo: la página renderiza sin reventar.
- [ ] Probado en móvil: el visor ocupa el ancho y no genera scroll horizontal.
- [ ] `OnPush`, `input()`, `output()` y signals; sin `ngClass` ni `ngStyle`.
