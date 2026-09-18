# 🖨️ Componente de previsualización de certificados (Angular 20)

Guía para construir, dentro de la feature `certificates`, una pantalla que previsualice **cualquier** certificado del sistema.

El componente recibe un **enum** con el tipo de certificado y, según ese valor, resuelve la plantilla PDFMake correspondiente y le entrega el resultado al visor de PDF que ya existe en `shared/components/pdf/`.

- **Stack:** Angular 20 · standalone · signals · OnPush · PDFMake · Bootstrap 5 · SSR habilitado
- **Alias:** `@core`, `@shared`, `@features`, `@shared-styles`

---

## 1. 🎯 Alcance

| Sí construimos | No construimos |
|---|---|
| El componente reutilizable que recibe el enum y muestra la previsualización | El visor de PDF — ver documento aparte de `pdf-preview` |
| El registro de plantillas (enum → plantilla) | La generación de PDF en backend |
| La plantilla base con header, footer y firma comunes | El listado/tabla de certificados |
| La página con panel de parámetros + visor | La autenticación (ya resuelta con MSAL) |

**La idea central:** el componente no conoce ningún certificado en particular. Conoce un **contrato** (`CertificateTemplate`) y un **registro**. Agregar un tipo nuevo no toca el componente ni la página.

---

## 2. 👁️ El visor: `app-pdf-preview`

La previsualización la pinta el componente compartido `shared/components/pdf-preview/`, documentado en
[componente-previsualizacion-pdf-angular.md](componente-previsualizacion-pdf-angular.md). Es de **solo lectura**:
sin descargar, sin imprimir y sin abrir archivo.

Su contrato es el único punto de contacto entre esta feature y el visor:

| Entrada | Qué le pasa esta feature |
|---|---|
| `src` | El `Blob` que devuelve la generación con PDFMake. También acepta una URL si el PDF lo genera el backend. |
| `fileName` | El nombre que arma la plantilla en `buildFileName`. |
| `height` | `'75vh'` en esta página. |

Como recibe el `Blob` directo, esta feature **no** crea object URLs ni tiene que revocarlas.

La descarga no vive en el visor: es un botón de la toolbar de la página (sección 10), habilitado solo
cuando el documento está listo. Así se controla desde el negocio quién puede descargar y cuándo.

---

## 3. 📁 Archivos a crear

```text
src/app/features/certificates/
├── domain/
│   ├── certificate-type.enum.ts              ⭐ el enum
│   ├── certificate-field.model.ts            parámetros que declara cada plantilla
│   └── certificate-template.ts               ⭐ el contrato + InjectionToken
│
├── infraestructure/
│   ├── certificate-template.registry.ts      ⭐ enum → plantilla
│   ├── certificate-assets.service.ts         logo y firma como dataURL (cacheados)
│   ├── pdfmake.service.ts                    carga diferida de PDFMake → Blob
│   ├── certificates.service.ts               datos del certificado desde la API
│   └── templates/
│       ├── base-certificate.template.ts      ⭐ header + footer + firma comunes
│       ├── labor-certificate.template.ts
│       └── severance-certificate.template.ts
│
├── application/
│   ├── certificate-preview.facade.ts         orquesta datos + plantilla + PDF
│   └── certificate-preview.providers.ts      ⭐ registro de plantillas (1 línea por tipo)
│
└── presentation/
    ├── certificate-preview/                  ⭐ COMPONENTE REUTILIZABLE (recibe el enum)
    │   ├── certificate-preview.component.ts
    │   ├── certificate-preview.component.html
    │   └── certificate-preview.component.scss
    ├── certificate-params-panel/             panel izquierdo (tonto)
    │   ├── certificate-params-panel.component.ts
    │   ├── certificate-params-panel.component.html
    │   └── certificate-params-panel.component.scss
    └── certificate-preview-page/             la página (layout split)
        ├── certificate-preview-page.component.ts
        ├── certificate-preview-page.component.html
        └── certificate-preview-page.component.scss
```

---

## 4. 🎨 Diseño de la página

### Layout

Split de dos columnas: parámetros a la izquierda, documento a la derecha. El usuario ve el efecto de cada cambio sin perder de vista el certificado.

```text
┌──────────────────────────────────────────────────────────────┐
│  Certificados                      [⬇ Descargar]  [✉ Enviar] │  ← toolbar
├───────────────────────┬──────────────────────────────────────┤
│ TIPO DE CERTIFICADO   │   ┌────────────────────────────────┐ │
│  ◉ Laboral            │   │  [logo]              DOC S.A.  │ │
│  ○ Cesantías          │   │ ────────────────────────────── │ │
│  ○ Ingresos y reten.  │   │                                │ │
│                       │   │     CERTIFICACIÓN LABORAL      │ │
│ ─────────────────     │   │                                │ │
│ PARÁMETROS            │   │  Bogotá D.C., 18 de sept...    │ │
│                       │   │                                │ │
│ Dirigido a            │   │  A QUIEN INTERESE:             │ │
│ [___________________] │   │                                │ │
│                       │   │  DOC certifica que el(la)      │ │
│ ☑ Incluir salario     │   │  señor(a)...                   │ │
│                       │   │  ┌──────────────────────────┐  │ │
│ Ciudad                │   │  │  tabla de detalle        │  │ │
│ [Bogotá D.C.       ▾] │   │  └──────────────────────────┘  │ │
│                       │   │                                │ │
│                       │   │        ____________            │ │
│ [ Restablecer ]       │   │        Nombre firmante         │ │
│                       │   │ ── Página 1 de 1 ───────────── │ │
│                       │   └────────────────────────────────┘ │
└───────────────────────┴──────────────────────────────────────┘
      col-lg-4 (sticky)              col-lg-8 (scroll)
```

### Rejilla y espaciado (Bootstrap 5)

| Breakpoint | Comportamiento |
|---|---|
| `≥ lg` (992px) | `col-lg-4` panel + `col-lg-8` visor. Panel con `position: sticky; top: 1rem`. |
| `md` | `col-md-5` / `col-md-7`. |
| `< md` | Una sola columna: panel arriba, visor abajo. Botón **Previsualizar** fijo al pie (`position: sticky; bottom: 0`). |

Gutter `g-3`, padding de tarjetas `p-3`, radio `0.5rem`, separación entre grupos de campos `mb-3`.

### Los cuatro estados de la zona del visor

Ninguno puede faltar: el PDF tarda en armarse y puede fallar.

```text
IDLE (sin tipo seleccionado)        LOADING
┌──────────────────────────┐        ┌──────────────────────────┐
│                          │        │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  │
│         📄               │        │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓      │
│  Selecciona un tipo de   │        │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  │
│  certificado para ver    │        │  ▓▓▓▓▓▓▓▓▓▓▓▓            │
│  la previsualización     │        │                          │
│                          │        │  Generando documento...  │
└──────────────────────────┘        └──────────────────────────┘
        texto-muted                  skeleton-loader de shared

READY                                ERROR
┌──────────────────────────┐        ┌──────────────────────────┐
│  [ visor de PDF ]        │        │  ⚠ No se pudo generar    │
│                          │        │    el certificado.       │
│                          │        │    <detalle del error>   │
│                          │        │                          │
│                          │        │      [ Reintentar ]      │
└──────────────────────────┘        └──────────────────────────┘
```

Para `LOADING` reutiliza `shared/components/skeleton-loader`. Para `ERROR`, el patrón de alertas que ya usa la app (`alert-notification` / SweetAlert2 solo para acciones destructivas, aquí basta la alerta en línea).

### Detalles de interacción

- **Cambio de tipo** → recarga datos desde la API (una vez por tipo) y regenera el PDF.
- **Cambio de parámetro** → regenera **solo** el PDF, sin ir a red, con `debounceTime(400)` para no armar un documento por cada tecla.
- **Descargar** deshabilitado mientras no haya un PDF listo.
- El tipo seleccionado se refleja en la URL (`?tipo=LABORAL`) para poder compartir el enlace y para que F5 no pierda el contexto.

### Accesibilidad

- Selector de tipo como grupo de radios reales (`role="radiogroup"`, navegable con flechas), no `div` clickeables.
- Cada campo con `<label for>` explícito.
- La zona del visor con `aria-live="polite"` y `aria-busy` durante la generación, para que un lector de pantalla anuncie "Generando documento" / "Documento listo".
- Foco visible en todos los controles; no eliminar el `outline`.
- Contraste mínimo AA sobre el gris del fondo del visor.

### Reglas de estilo del proyecto

- Sin `ngClass` ni `ngStyle`: usar `[class.is-active]="..."`.
- Clases utilitarias de Bootstrap primero; SCSS propio solo para lo que Bootstrap no cubre (sticky, alto del visor, fondo del lienzo).
- Reutilizar tokens de `@shared-styles`.

---

## 5. 1️⃣ Domain: el enum y los contratos

### `domain/certificate-type.enum.ts`

```ts
/** Tipos de certificado que la aplicación sabe previsualizar. */
export enum CertificateType {
  Laboral = 'LABORAL',
  Cesantias = 'CESANTIAS',
  IngresosRetenciones = 'INGRESOS_RETENCIONES',
}
```

> Enum de **strings**, no numérico: viaja legible en la URL (`?tipo=LABORAL`), en logs y hacia la API, y no se rompe si mañana se reordenan los valores.

### `domain/certificate-field.model.ts`

Cada plantilla declara qué parámetros necesita. Gracias a esto el panel izquierdo es genérico: sirve para cualquier certificado presente y futuro.

```ts
export type CertificateFieldControl = 'text' | 'textarea' | 'checkbox' | 'select' | 'date';

export interface CertificateFieldOption {
  readonly value: string;
  readonly label: string;
}

export interface CertificateField {
  readonly key: string;
  readonly label: string;
  readonly control: CertificateFieldControl;
  readonly required?: boolean;
  readonly placeholder?: string;
  readonly maxLength?: number;
  readonly options?: readonly CertificateFieldOption[];
  readonly defaultValue?: string | boolean;
  /** Texto de ayuda bajo el campo. */
  readonly hint?: string;
}

export type CertificateParams = Record<string, string | boolean | null>;
```

### `domain/certificate-template.ts`

El contrato. Lo implementa cada certificado y es lo único que el componente conoce.

```ts
import { InjectionToken } from '@angular/core';
import type { TDocumentDefinitions } from 'pdfmake/interfaces';
import { CertificateType } from './certificate-type.enum';
import { CertificateField, CertificateParams } from './certificate-field.model';

/** Recursos comunes que la plantilla base necesita para el header, el footer y la firma. */
export interface CertificateTemplateContext {
  readonly logoDataUrl: string | null;
  readonly signatureDataUrl: string | null;
  readonly generatedAt: Date;
}

export interface CertificateTemplate<TData = unknown> {
  /** Clave de registro: por este valor lo encuentra el componente. */
  readonly type: CertificateType;
  readonly title: string;
  readonly description?: string;

  /** Parámetros que el panel izquierdo debe renderizar para este certificado. */
  readonly fields: readonly CertificateField[];

  /** Trae de la API los datos que la plantilla necesita. */
  loadData(params: CertificateParams): Promise<TData>;

  /** Arma el documento PDFMake. Aquí NO va lógica de red. */
  build(
    data: TData,
    params: CertificateParams,
    context: CertificateTemplateContext,
  ): TDocumentDefinitions;

  buildFileName(data: TData, params: CertificateParams): string;
}

/** Token multi: cada plantilla se registra aquí. */
export const CERTIFICATE_TEMPLATE = new InjectionToken<readonly CertificateTemplate[]>(
  'CERTIFICATE_TEMPLATE',
);
```

---

## 6. 2️⃣ Infrastructure: registro, assets y PDFMake

### `infraestructure/certificate-template.registry.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { CERTIFICATE_TEMPLATE, CertificateTemplate } from '../domain/certificate-template';
import { CertificateType } from '../domain/certificate-type.enum';

@Injectable()
export class CertificateTemplateRegistry {
  private readonly templates = new Map<CertificateType, CertificateTemplate>(
    inject(CERTIFICATE_TEMPLATE, { optional: true })?.map((template) => [template.type, template]) ?? [],
  );

  /** Para el selector de tipo del panel izquierdo. */
  list(): readonly CertificateTemplate[] {
    return [...this.templates.values()];
  }

  get(type: CertificateType): CertificateTemplate {
    const template = this.templates.get(type);
    if (!template) {
      throw new Error(
        `No hay plantilla registrada para "${type}". Agrégala en certificate-preview.providers.ts`,
      );
    }
    return template;
  }

  has(type: CertificateType): boolean {
    return this.templates.has(type);
  }
}
```

> **No lleva `providedIn: 'root'`.** Se provee junto con las plantillas en el componente de página (sección 10), para que todo el código de plantillas viaje en el chunk perezoso de la ruta y no en el bundle inicial.

### `infraestructure/certificate-assets.service.ts`

**Gotcha de PDFMake:** en el navegador las imágenes deben ser **dataURL en base64**. Una URL `http` no se descarga sola; el documento sale sin imagen o revienta.

```ts
import { Injectable, inject, PLATFORM_ID } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import { HttpClient } from '@angular/common/http';
import { firstValueFrom } from 'rxjs';

@Injectable({ providedIn: 'root' })
export class CertificateAssetsService {
  private readonly http = inject(HttpClient);
  private readonly platformId = inject(PLATFORM_ID);
  private readonly cache = new Map<string, Promise<string | null>>();

  /** Convierte un asset a dataURL y lo cachea. Devuelve null si falla: el PDF debe salir igual. */
  toDataUrl(url: string | null | undefined): Promise<string | null> {
    if (!url || !isPlatformBrowser(this.platformId)) return Promise.resolve(null);

    const cached = this.cache.get(url);
    if (cached) return cached;

    const promise = firstValueFrom(this.http.get(url, { responseType: 'blob' }))
      .then((blob) => this.readAsDataUrl(blob))
      .catch(() => null);

    this.cache.set(url, promise);
    return promise;
  }

  private readAsDataUrl(blob: Blob): Promise<string> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result as string);
      reader.onerror = () => reject(reader.error);
      reader.readAsDataURL(blob);
    });
  }
}
```

### `infraestructure/pdfmake.service.ts`

```ts
import { Injectable, inject, PLATFORM_ID } from '@angular/core';
import { isPlatformBrowser } from '@angular/common';
import type { TDocumentDefinitions } from 'pdfmake/interfaces';

@Injectable({ providedIn: 'root' })
export class PdfMakeService {
  private readonly platformId = inject(PLATFORM_ID);
  private pdfMakePromise?: Promise<any>;

  async toBlob(docDefinition: TDocumentDefinitions): Promise<Blob> {
    const pdfMake = await this.load();
    return new Promise<Blob>((resolve, reject) => {
      try {
        pdfMake.createPdf(docDefinition).getBlob(resolve);
      } catch (error) {
        reject(error);
      }
    });
  }

  async download(docDefinition: TDocumentDefinitions, fileName: string): Promise<void> {
    const pdfMake = await this.load();
    pdfMake.createPdf(docDefinition).download(fileName);
  }

  /** Carga diferida: PDFMake y sus fuentes pesan; no deben entrar al bundle inicial. */
  private load(): Promise<any> {
    if (!isPlatformBrowser(this.platformId)) {
      // SSR: PDFMake necesita window/document. La vista debe mostrar el estado vacío.
      return Promise.reject(new Error('La previsualización solo está disponible en el navegador.'));
    }
    this.pdfMakePromise ??= import('pdfmake/build/pdfmake').then(async (module) => {
      const pdfMake = (module as any).default ?? module;
      const fonts: any = await import('pdfmake/build/vfs_fonts');
      pdfMake.vfs = fonts.pdfMake?.vfs ?? fonts.default?.pdfMake?.vfs ?? fonts.vfs;
      return pdfMake;
    });
    return this.pdfMakePromise;
  }
}
```

> Si ya tienes PDFMake funcionando en el visor actual, **reutiliza esa misma forma de cargarlo y de enlazar `vfs`** — la ruta de `vfs_fonts` cambia entre versiones de PDFMake y no vale la pena pelear dos veces con eso.

---

## 7. 3️⃣ La plantilla base: header, footer y firma comunes

Es el equivalente en el front a lo que el backend hace con su documento base: **lo único que comparten todos los certificados**.

### `infraestructure/templates/base-certificate.template.ts`

```ts
import type { Content, TDocumentDefinitions } from 'pdfmake/interfaces';
import { CertificateTemplateContext } from '../../domain/certificate-template';

const PALETTE = {
  primary: '#004B87',
  text: '#1F2933',
  muted: '#6B7280',
  line: '#D8DEE6',
} as const;

const COMPANY = {
  name: 'DOC S.A.',
  document: 'NIT 900.000.000-0',
  address: 'Bogotá D.C.',
} as const;

interface BaseDocumentOptions {
  readonly title: string;
  readonly showPageNumbers?: boolean;
}

/**
 * Envuelve el contenido propio de cada certificado con el header y el footer
 * comunes. Ninguna plantilla concreta debe redefinirlos.
 */
export function buildBaseDocument(
  content: Content,
  context: CertificateTemplateContext,
  options: BaseDocumentOptions,
): TDocumentDefinitions {
  return {
    info: { title: options.title, author: COMPANY.name },
    pageSize: 'A4',
    // ⚠ El margen superior e inferior debe reservar el alto de header y footer,
    //   si no, el contenido se monta encima de ellos.
    pageMargins: [56, 110, 56, 70],
    header: () => buildHeader(context),
    footer: (currentPage: number, pageCount: number) =>
      buildFooter(context, options, currentPage, pageCount),
    content,
    defaultStyle: { fontSize: 10, lineHeight: 1.35, color: PALETTE.text },
    styles: {
      documentTitle: { fontSize: 14, bold: true, color: PALETTE.primary, alignment: 'center' },
      sectionLabel: { fontSize: 9, bold: true, color: PALETTE.muted },
      body: { alignment: 'justify', margin: [0, 6, 0, 6] },
    },
  };
}

function buildHeader(context: CertificateTemplateContext): Content {
  return {
    margin: [56, 24, 56, 0],
    stack: [
      {
        columns: [
          context.logoDataUrl
            ? { image: context.logoDataUrl, fit: [120, 42] }
            : { text: COMPANY.name, bold: true, color: PALETTE.primary, fontSize: 12 },
          {
            alignment: 'right',
            stack: [
              { text: COMPANY.name, bold: true, fontSize: 9, color: PALETTE.primary },
              { text: COMPANY.document, fontSize: 8, color: PALETTE.muted },
              { text: COMPANY.address, fontSize: 8, color: PALETTE.muted },
            ],
          },
        ],
      },
      {
        margin: [0, 8, 0, 0],
        canvas: [{ type: 'line', x1: 0, y1: 0, x2: 483, y2: 0, lineWidth: 1, lineColor: PALETTE.line }],
      },
    ],
  };
}

function buildFooter(
  context: CertificateTemplateContext,
  options: BaseDocumentOptions,
  currentPage: number,
  pageCount: number,
): Content {
  return {
    margin: [56, 10, 56, 0],
    stack: [
      { canvas: [{ type: 'line', x1: 0, y1: 0, x2: 483, y2: 0, lineWidth: 1, lineColor: PALETTE.line }] },
      {
        margin: [0, 6, 0, 0],
        columns: [
          {
            fontSize: 7,
            color: PALETTE.muted,
            stack: [
              { text: 'Documento generado electrónicamente. No requiere firma manuscrita.' },
              { text: `Generado el ${formatDateTime(context.generatedAt)}` },
            ],
          },
          options.showPageNumbers === false
            ? { text: '' }
            : {
                text: `Página ${currentPage} de ${pageCount}`,
                alignment: 'right',
                fontSize: 7,
                color: PALETTE.muted,
              },
        ],
      },
    ],
  };
}

/** Bloque de firma reutilizable: alto fijo haya o no imagen, para que la línea no salte. */
export function signatureBlock(
  context: CertificateTemplateContext,
  signer: { readonly name: string; readonly position: string },
): Content {
  return {
    width: 220,
    margin: [0, 40, 0, 0],
    stack: [
      context.signatureDataUrl
        ? { image: context.signatureDataUrl, fit: [180, 55], margin: [0, 0, 0, 4] }
        : { text: ' ', margin: [0, 0, 0, 40] },
      { canvas: [{ type: 'line', x1: 0, y1: 0, x2: 200, y2: 0, lineWidth: 0.8, lineColor: PALETTE.text }] },
      { text: signer.name, bold: true, fontSize: 10, margin: [0, 6, 0, 0] },
      { text: signer.position, fontSize: 9, color: PALETTE.muted },
    ],
  };
}

function formatDateTime(date: Date): string {
  return new Intl.DateTimeFormat('es-CO', { dateStyle: 'short', timeStyle: 'short' }).format(date);
}
```

### Una plantilla concreta: `templates/labor-certificate.template.ts`

Fíjate en lo que **no** está: header, footer, márgenes ni paginación.

```ts
import { Injectable, inject } from '@angular/core';
import type { Content, TDocumentDefinitions } from 'pdfmake/interfaces';
import { CertificateTemplate, CertificateTemplateContext } from '../../domain/certificate-template';
import { CertificateField, CertificateParams } from '../../domain/certificate-field.model';
import { CertificateType } from '../../domain/certificate-type.enum';
import { CertificatesService } from '../certificates.service';
import { LaborCertificateData } from '../../domain/labor-certificate.model';
import { buildBaseDocument, signatureBlock } from './base-certificate.template';

@Injectable()
export class LaborCertificateTemplate implements CertificateTemplate<LaborCertificateData> {
  private readonly certificatesService = inject(CertificatesService);

  readonly type = CertificateType.Laboral;
  readonly title = 'Certificación laboral';
  readonly description = 'Certifica cargo, tipo de contrato y antigüedad.';

  readonly fields: readonly CertificateField[] = [
    {
      key: 'addressedTo',
      label: 'Dirigido a',
      control: 'text',
      placeholder: 'A quien interese',
      maxLength: 150,
      hint: 'Si lo dejas vacío, el certificado dice "A QUIEN INTERESE".',
    },
    { key: 'includeSalary', label: 'Incluir salario', control: 'checkbox', defaultValue: true },
  ];

  loadData(params: CertificateParams): Promise<LaborCertificateData> {
    return this.certificatesService.getLaborCertificateData(params);
  }

  buildFileName(data: LaborCertificateData): string {
    return `certificado-laboral-${data.employeeDocument}.pdf`;
  }

  build(
    data: LaborCertificateData,
    params: CertificateParams,
    context: CertificateTemplateContext,
  ): TDocumentDefinitions {
    const addressedTo = (params['addressedTo'] as string) || '';
    const includeSalary = params['includeSalary'] !== false;

    const content: Content = [
      { text: 'CERTIFICACIÓN LABORAL', style: 'documentTitle', margin: [0, 0, 0, 18] },
      { text: `${data.city}, ${formatLongDate(data.issueDate)}`, alignment: 'right' },
      {
        text: addressedTo ? `Señores ${addressedTo.toUpperCase()}:` : 'A QUIEN INTERESE:',
        bold: true,
        margin: [0, 14, 0, 0],
      },
      { text: this.buildBodyText(data), style: 'body' },
      this.buildDetailTable(data, includeSalary),
      {
        text: 'La presente certificación se expide a solicitud del interesado, para los fines que estime convenientes.',
        style: 'body',
      },
      signatureBlock(context, { name: data.signerName, position: data.signerPosition }),
    ];

    return buildBaseDocument(content, context, { title: this.title });
  }

  private buildBodyText(data: LaborCertificateData): string {
    const verb = data.isActive ? 'labora actualmente' : 'laboró';
    const period = data.isActive
      ? `desde el ${formatLongDate(data.hireDate)}`
      : `entre el ${formatLongDate(data.hireDate)} y el ${formatLongDate(data.terminationDate!)}`;

    return `DOC S.A. certifica que el(la) señor(a) ${data.employeeFullName}, identificado(a) con documento No. ${data.employeeDocument}, ${verb} en esta compañía ${period}, desempeñando el cargo de ${data.position} mediante ${data.contractType}.`;
  }

  private buildDetailTable(data: LaborCertificateData, includeSalary: boolean): Content {
    const rows: Content[][] = [
      [{ text: 'Cargo', bold: true }, { text: data.position }],
      [{ text: 'Tipo de contrato', bold: true }, { text: data.contractType }],
      [{ text: 'Fecha de ingreso', bold: true }, { text: formatShortDate(data.hireDate) }],
    ];

    if (includeSalary && data.monthlySalary) {
      rows.push([{ text: 'Salario mensual', bold: true }, { text: formatCurrency(data.monthlySalary) }]);
    }

    return {
      margin: [0, 8, 0, 8],
      table: { widths: [140, '*'], body: rows, dontBreakRows: true },
      layout: 'lightHorizontalLines',
    };
  }
}
```

*(`formatLongDate`, `formatShortDate` y `formatCurrency` van en `shared/utils` con `Intl` y locale `es-CO`.)*

---

## 8. 4️⃣ El componente reutilizable: recibe el enum

Este es el componente que pediste: **le pasas el enum y muestra el PDF**. No sabe nada de ningún certificado concreto.

### `presentation/certificate-preview/certificate-preview.component.ts`

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
} from '@angular/core';
import { CertificateType } from '../../domain/certificate-type.enum';
import { CertificateParams } from '../../domain/certificate-field.model';
import { CertificatePreviewFacade } from '../../application/certificate-preview.facade';
import { PdfPreviewComponent } from '@shared/components/pdf-preview/pdf-preview.component';
// import { SkeletonLoaderComponent } from '@shared/components/skeleton-loader/...';

@Component({
  selector: 'app-certificate-preview',
  imports: [PdfPreviewComponent /*, SkeletonLoaderComponent */],
  templateUrl: './certificate-preview.component.html',
  styleUrl: './certificate-preview.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CertificatePreviewComponent {
  private readonly facade = inject(CertificatePreviewFacade);

  /** ⭐ El tipo de certificado. Todo lo demás se deriva de aquí. */
  readonly type = input.required<CertificateType>();
  readonly params = input<CertificateParams>({});

  readonly generated = output<{ fileName: string }>();
  readonly failed = output<Error>();

  /** Carga datos + arma el PDF cada vez que cambian el tipo o los parámetros. */
  readonly previewResource = resource({
    params: () => ({ type: this.type(), params: this.params() }),
    loader: ({ params }) => this.facade.build(params.type, params.params),
  });

  readonly title = computed(() => this.facade.titleOf(this.type()));
  readonly isReady = computed(() => this.previewResource.hasValue() && !this.previewResource.isLoading());

  /** El visor recibe el Blob directo: aquí no se crean object URLs. */
  readonly blob = computed(() => this.previewResource.value()?.blob ?? null);
  readonly fileName = computed(() => this.previewResource.value()?.fileName ?? 'certificado.pdf');

  constructor() {
    effect(() => {
      const value = this.previewResource.value();
      if (value) this.generated.emit({ fileName: value.fileName });

      const error = this.previewResource.error();
      if (error) this.failed.emit(error as Error);
    });
  }

  reload(): void {
    this.previewResource.reload();
  }

  download(): void {
    const value = this.previewResource.value();
    if (value) this.facade.download(value);
  }
}
```

> **`resource()` es API experimental en Angular 20.** Si tu versión todavía usa la firma anterior, renombra `params:` por `request:` en ambos lugares. Si prefieres no depender de ella, el equivalente estable es un `effect()` que llama al facade y escribe en signals de estado — mismo diseño, más líneas.

### `certificate-preview.component.html`

```html
<div class="certificate-preview" aria-live="polite" [attr.aria-busy]="previewResource.isLoading()">
  @if (previewResource.isLoading()) {
    <div class="certificate-preview__state">
      <!-- <app-skeleton-loader type="document" /> -->
      <p class="text-muted mt-3 mb-0">Generando documento…</p>
    </div>
  } @else if (previewResource.error(); as error) {
    <div class="certificate-preview__state">
      <div class="alert alert-danger text-center" role="alert">
        <p class="fw-semibold mb-1">No se pudo generar el certificado.</p>
        <p class="small mb-3">{{ error.message }}</p>
        <button type="button" class="btn btn-outline-danger btn-sm" (click)="reload()">
          Reintentar
        </button>
      </div>
    </div>
  } @else if (isReady()) {
    <app-pdf-preview [src]="blob()" [fileName]="fileName()" height="75vh" />
  } @else {
    <div class="certificate-preview__state text-center text-muted">
      <i class="fa-regular fa-file-lines fa-2x mb-2" aria-hidden="true"></i>
      <p class="mb-0">Selecciona un tipo de certificado para ver la previsualización.</p>
    </div>
  }
</div>
```

### `certificate-preview.component.scss`

```scss
.certificate-preview {
  min-height: 60vh;
  background-color: var(--bs-gray-200, #e9ecef);
  border-radius: 0.5rem;
  overflow: auto;

  &__state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 60vh;
    padding: 2rem;
  }
}
```

---

## 9. 5️⃣ El facade: orquestación

### `application/certificate-preview.facade.ts`

```ts
import { Injectable, inject } from '@angular/core';
import { CertificateTemplateRegistry } from '../infraestructure/certificate-template.registry';
import { CertificateAssetsService } from '../infraestructure/certificate-assets.service';
import { PdfMakeService } from '../infraestructure/pdfmake.service';
import { CertificateType } from '../domain/certificate-type.enum';
import { CertificateParams } from '../domain/certificate-field.model';
import { CertificateTemplateContext } from '../domain/certificate-template';
import { environment } from '@enviroments/enviroment';

export interface CertificatePreviewResult {
  readonly blob: Blob;
  readonly fileName: string;
  readonly docDefinition: unknown;
}

@Injectable()
export class CertificatePreviewFacade {
  private readonly registry = inject(CertificateTemplateRegistry);
  private readonly assets = inject(CertificateAssetsService);
  private readonly pdfMake = inject(PdfMakeService);

  availableTemplates() {
    return this.registry.list();
  }

  titleOf(type: CertificateType): string {
    return this.registry.has(type) ? this.registry.get(type).title : '';
  }

  fieldsOf(type: CertificateType) {
    return this.registry.has(type) ? this.registry.get(type).fields : [];
  }

  /** ⭐ enum → plantilla → datos → documento → Blob. */
  async build(type: CertificateType, params: CertificateParams): Promise<CertificatePreviewResult> {
    const template = this.registry.get(type);

    const [data, context] = await Promise.all([
      template.loadData(params),
      this.buildContext(),
    ]);

    const docDefinition = template.build(data, params, context);
    const blob = await this.pdfMake.toBlob(docDefinition);

    return { blob, fileName: template.buildFileName(data, params), docDefinition };
  }

  download(result: CertificatePreviewResult): void {
    const link = document.createElement('a');
    link.href = URL.createObjectURL(result.blob);
    link.download = result.fileName;
    link.click();
    URL.revokeObjectURL(link.href);
  }

  private async buildContext(): Promise<CertificateTemplateContext> {
    const [logoDataUrl, signatureDataUrl] = await Promise.all([
      this.assets.toDataUrl('assets/img/logo-certificados.png'),
      this.assets.toDataUrl('assets/img/firma-gestion-humana.png'),
    ]);

    return { logoDataUrl, signatureDataUrl, generatedAt: new Date() };
  }
}
```

> Si la firma depende del firmante que devuelve la API, mueve `signatureDataUrl` a `loadData` de cada plantilla y pásalo dentro de `data`. El `context` queda solo para lo verdaderamente común.

---

## 10. 6️⃣ La página: panel + visor

### `application/certificate-preview.providers.ts`

**El único archivo que se toca al agregar un certificado nuevo.**

```ts
import { Provider } from '@angular/core';
import { CERTIFICATE_TEMPLATE } from '../domain/certificate-template';
import { CertificateTemplateRegistry } from '../infraestructure/certificate-template.registry';
import { CertificatePreviewFacade } from './certificate-preview.facade';
import { LaborCertificateTemplate } from '../infraestructure/templates/labor-certificate.template';
import { SeveranceCertificateTemplate } from '../infraestructure/templates/severance-certificate.template';

export const certificatePreviewProviders: Provider[] = [
  CertificateTemplateRegistry,
  CertificatePreviewFacade,

  // ── Una línea por cada tipo de certificado ────────────────────────
  { provide: CERTIFICATE_TEMPLATE, useClass: LaborCertificateTemplate, multi: true },
  { provide: CERTIFICATE_TEMPLATE, useClass: SeveranceCertificateTemplate, multi: true },
];
```

### `presentation/certificate-params-panel/certificate-params-panel.component.ts`

Componente tonto: recibe los campos que declaró la plantilla y emite los valores.

```ts
import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { CertificateField, CertificateParams } from '../../domain/certificate-field.model';

@Component({
  selector: 'app-certificate-params-panel',
  imports: [FormsModule],
  templateUrl: './certificate-params-panel.component.html',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CertificateParamsPanelComponent {
  readonly fields = input.required<readonly CertificateField[]>();
  readonly value = input<CertificateParams>({});
  readonly valueChange = output<CertificateParams>();

  update(key: string, next: string | boolean | null): void {
    this.valueChange.emit({ ...this.value(), [key]: next });
  }
}
```

```html
@for (field of fields(); track field.key) {
  <div class="mb-3">
    @switch (field.control) {
      @case ('checkbox') {
        <div class="form-check">
          <input
            class="form-check-input"
            type="checkbox"
            [id]="field.key"
            [checked]="$any(value()[field.key]) ?? field.defaultValue ?? false"
            (change)="update(field.key, $any($event.target).checked)" />
          <label class="form-check-label" [for]="field.key">{{ field.label }}</label>
        </div>
      }
      @case ('select') {
        <label class="form-label" [for]="field.key">{{ field.label }}</label>
        <select
          class="form-select"
          [id]="field.key"
          [value]="$any(value()[field.key]) ?? field.defaultValue ?? ''"
          (change)="update(field.key, $any($event.target).value)">
          @for (option of field.options ?? []; track option.value) {
            <option [value]="option.value">{{ option.label }}</option>
          }
        </select>
      }
      @case ('textarea') {
        <label class="form-label" [for]="field.key">{{ field.label }}</label>
        <textarea
          class="form-control"
          rows="3"
          [id]="field.key"
          [maxlength]="field.maxLength ?? null"
          [placeholder]="field.placeholder ?? ''"
          [value]="$any(value()[field.key]) ?? ''"
          (input)="update(field.key, $any($event.target).value)"></textarea>
      }
      @default {
        <label class="form-label" [for]="field.key">{{ field.label }}</label>
        <input
          class="form-control"
          [type]="field.control === 'date' ? 'date' : 'text'"
          [id]="field.key"
          [maxlength]="field.maxLength ?? null"
          [placeholder]="field.placeholder ?? ''"
          [value]="$any(value()[field.key]) ?? ''"
          (input)="update(field.key, $any($event.target).value)" />
      }
    }

    @if (field.hint) {
      <div class="form-text">{{ field.hint }}</div>
    }
  </div>
}
```

### `presentation/certificate-preview-page/certificate-preview-page.component.ts`

```ts
import { ChangeDetectionStrategy, Component, computed, inject, signal } from '@angular/core';
import { ActivatedRoute, Router } from '@angular/router';
import { toObservable, toSignal } from '@angular/core/rxjs-interop';
import { debounceTime } from 'rxjs';
import { CertificateType } from '../../domain/certificate-type.enum';
import { CertificateParams } from '../../domain/certificate-field.model';
import { CertificatePreviewFacade } from '../../application/certificate-preview.facade';
import { certificatePreviewProviders } from '../../application/certificate-preview.providers';
import { CertificatePreviewComponent } from '../certificate-preview/certificate-preview.component';
import { CertificateParamsPanelComponent } from '../certificate-params-panel/certificate-params-panel.component';

@Component({
  selector: 'app-certificate-preview-page',
  imports: [CertificatePreviewComponent, CertificateParamsPanelComponent],
  providers: certificatePreviewProviders,
  templateUrl: './certificate-preview-page.component.html',
  styleUrl: './certificate-preview-page.component.scss',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class CertificatePreviewPageComponent {
  private readonly facade = inject(CertificatePreviewFacade);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);

  readonly templates = this.facade.availableTemplates();

  readonly selectedType = signal<CertificateType | null>(
    this.readTypeFromUrl() ?? this.templates[0]?.type ?? null,
  );

  readonly fields = computed(() => {
    const type = this.selectedType();
    return type ? this.facade.fieldsOf(type) : [];
  });

  /** Valor inmediato para que el formulario no se sienta lento. */
  readonly draftParams = signal<CertificateParams>({});

  /** Valor con rebote: es el que dispara la regeneración del PDF. */
  readonly params = toSignal(toObservable(this.draftParams).pipe(debounceTime(400)), {
    initialValue: {} as CertificateParams,
  });

  selectType(type: CertificateType): void {
    this.selectedType.set(type);
    this.draftParams.set(this.defaultParamsFor(type));
    this.router.navigate([], {
      relativeTo: this.route,
      queryParams: { tipo: type },
      queryParamsHandling: 'merge',
      replaceUrl: true,
    });
  }

  updateParams(next: CertificateParams): void {
    this.draftParams.set(next);
  }

  reset(): void {
    const type = this.selectedType();
    if (type) this.draftParams.set(this.defaultParamsFor(type));
  }

  private defaultParamsFor(type: CertificateType): CertificateParams {
    return Object.fromEntries(
      this.facade.fieldsOf(type).map((field) => [field.key, field.defaultValue ?? null]),
    );
  }

  private readTypeFromUrl(): CertificateType | null {
    const raw = this.route.snapshot.queryParamMap.get('tipo');
    return raw && Object.values(CertificateType).includes(raw as CertificateType)
      ? (raw as CertificateType)
      : null;
  }
}
```

### `certificate-preview-page.component.html`

```html
<section class="container-fluid py-3">
  <header class="d-flex flex-wrap align-items-center justify-content-between gap-2 mb-3">
    <h1 class="h4 mb-0">Certificados</h1>
    <div class="d-flex gap-2">
      <button type="button" class="btn btn-outline-secondary btn-sm" (click)="reset()">
        Restablecer
      </button>
      <button
        type="button"
        class="btn btn-primary btn-sm"
        [disabled]="!preview.isReady()"
        (click)="preview.download()">
        <i class="fa-solid fa-download me-1" aria-hidden="true"></i> Descargar
      </button>
    </div>
  </header>

  <div class="row g-3">
    <aside class="col-12 col-md-5 col-lg-4">
      <div class="card certificate-panel">
        <div class="card-body">
          <h2 class="h6 text-uppercase text-muted">Tipo de certificado</h2>

          <div role="radiogroup" aria-label="Tipo de certificado" class="mb-4">
            @for (template of templates; track template.type) {
              <div class="form-check">
                <input
                  class="form-check-input"
                  type="radio"
                  name="certificate-type"
                  [id]="template.type"
                  [value]="template.type"
                  [checked]="selectedType() === template.type"
                  (change)="selectType(template.type)" />
                <label class="form-check-label" [for]="template.type">
                  {{ template.title }}
                  @if (template.description) {
                    <span class="d-block form-text">{{ template.description }}</span>
                  }
                </label>
              </div>
            }
          </div>

          @if (fields().length) {
            <h2 class="h6 text-uppercase text-muted">Parámetros</h2>
            <app-certificate-params-panel
              [fields]="fields()"
              [value]="draftParams()"
              (valueChange)="updateParams($event)" />
          }
        </div>
      </div>
    </aside>

    <div class="col-12 col-md-7 col-lg-8">
      @if (selectedType(); as type) {
        <app-certificate-preview #preview [type]="type" [params]="params()" />
      }
    </div>
  </div>
</section>
```

> `#preview` da acceso a `isReady()` y `download()` del componente hijo desde la toolbar. Si prefieres no usar template reference variables, sube ese estado al facade.

### `certificate-preview-page.component.scss`

```scss
.certificate-panel {
  @media (min-width: 768px) {
    position: sticky;
    top: 1rem;
  }
}
```

### Ruta en `src/app/app.routes.ts`

```ts
{
  path: 'certificados/previsualizar',
  canActivate: [permissionGuard],
  data: { permissionPath: 'certificates' },
  loadComponent: () =>
    import('@features/certificates/presentation/certificate-preview-page/certificate-preview-page.component')
      .then(m => m.CertificatePreviewPageComponent),
}
```

---

## 11. ➕ Agregar un certificado nuevo

Tres archivos y una línea. **No se toca el componente, ni la página, ni el panel de parámetros.**

| # | Acción |
|---|---|
| 1 | Agregar el valor al enum en `certificate-type.enum.ts`. |
| 2 | Crear el modelo de datos en `domain/` y el método de API en `certificates.service.ts`. |
| 3 | Crear `templates/<nuevo>-certificate.template.ts` implementando `CertificateTemplate`: declara `fields`, resuelve `loadData` y arma el `content`; envuélvelo con `buildBaseDocument(...)`. |
| 4 | Registrar: `{ provide: CERTIFICATE_TEMPLATE, useClass: NuevoTemplate, multi: true }`. |

El header, el footer, la paginación y el bloque de firma se heredan solos. El panel de parámetros se dibuja solo a partir de `fields`.

---

## 12. 🐛 Errores comunes

| Síntoma | Causa | Solución |
|---|---|---|
| Error en build/arranque SSR: `window is not defined` | PDFMake es solo de navegador y SSR está habilitado | `isPlatformBrowser` antes de cargarlo (ya está en `PdfMakeService`), y `import()` dinámico, nunca estático. |
| El logo o la firma no aparecen | PDFMake en navegador **no descarga URLs**: necesita dataURL base64 | Usar `CertificateAssetsService.toDataUrl()`. |
| El contenido se monta sobre el header | `pageMargins` no reserva el alto del header/footer | Subir el margen superior/inferior en `buildBaseDocument`. |
| La pestaña consume memoria hasta colgarse | Object URLs creadas a mano | Pasar el `Blob` directo a `app-pdf-preview`. |
| El visor muestra el botón de descarga | Toolbar secundario activo | Ver la tabla de inputs en el documento de `pdf-preview`. |
| Se arma un PDF por cada tecla | Sin rebote en los parámetros | `debounceTime(400)` entre `draftParams` y `params`. |
| El bundle inicial crece ~1 MB | PDFMake importado estáticamente | `import('pdfmake/build/pdfmake')` diferido + plantillas provistas en la ruta, no en `root`. |
| Tildes o ñ salen mal con fuente propia | La fuente registrada no trae los glifos | Registrar la fuente completa en `vfs` o quedarse con Roboto. |
| Una tabla se parte entre páginas | Comportamiento por defecto | `dontBreakRows: true` en el `table`. |
| `No hay plantilla registrada para "X"` | Falta el provider | Agregar la línea en `certificate-preview.providers.ts`. |

---

## 13. ✅ Checklist

- [ ] `app-pdf-preview` creado y configurado sin botón de descarga (ver su propio documento).
- [ ] El enum es de strings y viaja en la URL (`?tipo=`).
- [ ] El componente `certificate-preview` no menciona ningún certificado concreto.
- [ ] `CertificateTemplateRegistry` y las plantillas se proveen en la página, no en `root`.
- [ ] PDFMake entra por `import()` dinámico y protegido con `isPlatformBrowser`.
- [ ] Logo y firma convertidos a dataURL y cacheados.
- [ ] Los cuatro estados (vacío, cargando, listo, error) están implementados y probados.
- [ ] Probadas 20 regeneraciones seguidas mirando memoria: no crece.
- [ ] Probado un certificado que ocupe 2+ páginas: header y footer se repiten y la paginación es correcta.
- [ ] Componentes con `OnPush`, `input()`, `output()`, `signal()`; sin `ngClass` ni `ngStyle`.
- [ ] Ruta registrada con `loadComponent`, `permissionGuard` y `data.permissionPath`.
- [ ] Navegación por teclado y `aria-live` verificados en el panel y el visor.
- [ ] Probado en móvil: panel arriba, visor abajo, sin scroll horizontal.
