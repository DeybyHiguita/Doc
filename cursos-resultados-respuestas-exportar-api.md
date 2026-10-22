# 📊 Cursos — Resultados: respuestas anónimas y exportación — API (.NET 8)

**Lo que se construye:**

| Qué | Dónde | Para qué |
|---|---|---|
| **Las respuestas del formulario** | `GET /api/courses/{id}/responses` | Ver en la pantalla de resultados cada respuesta (calidad, utilidad, conocimiento antes y después, comentario), **sin nombre, sin fecha y en orden aleatorio**. |
| **Exportar a Excel** | `GET /api/courses/{id}/results/export?format=xlsx` | Un libro para analizar, con cuatro hojas: un **Resumen** con barras y estrellas, **Por grupo**, **Personas** y **Respuestas (anónimas)**. |
| **Exportar a PDF** | `GET /api/courses/{id}/results/export?format=pdf` | Un **informe de una o dos páginas** para compartir: cifras, avance por grupo, calificaciones en barras y comentarios destacados. |

**Requiere:** el formulario de 5 preguntas ([cursos-formulario-finalizacion-api.md](cursos-formulario-finalizacion-api.md)): columnas `knowledge_before`, `knowledge_after` y `comments`, y el `RatingSummaryBuilder` que no cuenta el 0.

**El frontend** está en [cursos-resultados-respuestas-exportar-angular.md](cursos-resultados-respuestas-exportar-angular.md). **Base:** el código de la rama de cursos (`.claude/Cursos API`). ClosedXML y QuestPDF ya están en el proyecto (los usan `ExcelReportGenerator` y el certificado de cesantías).

---

## 1. Cómo se protege el anonimato

Las respuestas están en `course_rating`, que no tiene relación con la persona. Además, esta guía cuida que no se puedan cruzar con la lista de quién finalizó y cuándo:

| Regla | Por qué |
|---|---|
| **Sin fecha.** | La lista de personas muestra la fecha de finalización de cada una. Con la fecha de la respuesta se podría emparejar. |
| **Orden aleatorio y estable** (por `id`, que es un `Guid` aleatorio). | En el orden de envío, la primera respuesta sería la del primero en finalizar. |
| **Mínimo de respuestas** (`MinimumResponsesForSummary`, hoy 3). | Con una o dos respuestas se sabe de quién son. Por debajo del mínimo, la API devuelve solo el conteo. |
| **El grupo solo si todos los grupos llegan al mínimo** (`CanShowPerAssignment`). | La misma regla de los promedios por grupo: si no, un grupo de 2 personas delataría sus respuestas. |
| **En los archivos, las mismas reglas.** | La hoja de personas y la de respuestas van separadas, sin nada que las una. |

---

## 2. Archivos

```text
DOCCB.Application/
├── Contracts/Persistence/ICourseCompletionRepository.cs           ✏️ + 2 lecturas
├── Features/Courses/Application/
│   ├── Constants/CourseResultsConstants.cs                         nuevo
│   ├── DTOs/CourseResultsDtos.cs                                   nuevo
│   ├── Interfaces/ICourseResultsService.cs                         nuevo
│   ├── Services/CourseResultsService.cs                            nuevo: respuestas y exportación
│   ├── Exports/CourseResultsReport.cs                              nuevo: los datos de los dos archivos
│   ├── Exports/CourseResultsExcelWriter.cs                         nuevo ⭐ Excel
│   └── Exports/CourseResultsPdfWriter.cs                           nuevo ⭐ PDF
└── ApplicationServiceRegistration.cs                               ✏️

DOCCB.Infraestructure/Repositories/CourseCompletionRepository.cs    ✏️

WebApp/
├── Controllers/CoursesController.cs                                ✏️ + 2 acciones
├── Common/ResponseConstants/ApiResponseConstants.cs                ✏️
└── Program.cs                                                      ✏️ CORS expone Content-Disposition
```

---

## 3. Paso 1 — Las lecturas

### `Contracts/Persistence/ICourseCompletionRepository.cs` ✏️

```csharp
/// <summary>Una respuesta del formulario. Sin persona y sin fecha.</summary>
public sealed record AnonymousResponseRow(
    int AssignmentId, string? GroupName, byte Satisfaction, byte Usefulness, byte? KnowledgeBefore, byte? KnowledgeAfter, string? Comments);

/// <summary>Una persona asignada, para la hoja "Personas".</summary>
public sealed record ResultsPersonRow(
    int AssignmentId, string DisplayName, string Email, bool Completed, bool IsOverdue, DateTime? CompletedDate, string? Management);
```

En la interfaz:

```csharp
/// <summary>Respuestas del curso en orden aleatorio y estable (por id). assignmentId y withComments filtran.</summary>
Task<(IReadOnlyList<AnonymousResponseRow> Items, int Total)> GetResponsesAsync(
    int courseId, int? assignmentId, bool withComments, int skip, int take, CancellationToken ct);

/// <summary>Todas las personas asignadas al curso, por fecha límite y nombre.</summary>
Task<IReadOnlyList<ResultsPersonRow>> GetResultsPeopleAsync(int courseId, DateOnly today, CancellationToken ct);
```

### `Repositories/CourseCompletionRepository.cs` ✏️

```csharp
public Task<(IReadOnlyList<AnonymousResponseRow> Items, int Total)> GetResponsesAsync(
    int courseId, int? assignmentId, bool withComments, int skip, int take, CancellationToken ct) =>
    Guard<(IReadOnlyList<AnonymousResponseRow> Items, int Total)>(async () =>
    {
        var ratings = _context.Set<CourseRating>().AsNoTracking().Where(r => r.CourseId == courseId);

        if (assignmentId is int id)
            ratings = ratings.Where(r => r.AssignmentId == id);

        if (withComments)
            ratings = ratings.Where(r => r.Comments != null && r.Comments != "");

        var total = await ratings.CountAsync(ct);

        var items = await ratings
            // id es un Guid aleatorio: un orden estable que NO sigue el orden en que se enviaron.
            .OrderBy(r => r.Id)
            .Skip(skip)
            .Take(take)
            .Join(_context.Set<CourseAssignment>(), r => r.AssignmentId, a => a.Id, (r, a) => new AnonymousResponseRow(
                r.AssignmentId,
                a.UserGroup != null ? a.UserGroup.Name : null,
                r.Satisfaction,
                r.Usefulness,
                r.KnowledgeBefore,
                r.KnowledgeAfter,
                r.Comments))
            .ToListAsync(ct);

        return (items, total);
    });

public Task<IReadOnlyList<ResultsPersonRow>> GetResultsPeopleAsync(int courseId, DateOnly today, CancellationToken ct) =>
    Guard<IReadOnlyList<ResultsPersonRow>>(async () => await _dbSet
        .AsNoTracking()
        .Where(u => u.Assignment.CourseId == courseId)
        .OrderBy(u => u.Assignment.DueDate)
        .ThenBy(u => u.User.DisplayName)
        .Select(u => new ResultsPersonRow(
            u.AssignmentId,
            u.User.DisplayName,
            u.User.CorportativeEmail ?? string.Empty,
            u.Completion != null,
            u.Completion == null && u.Assignment.DueDate < today,
            u.Completion != null ? (DateTime?)u.Completion.CreatedDate : null,
            u.Completion != null ? u.Completion.ManagementName : null))
        .ToListAsync(ct));
```

> **El `Join` va después del `Take`:** primero se elige la página en `course_rating` y después se trae el nombre del grupo solo de esas filas.

---

## 4. Paso 2 — Constantes y DTOs

### `Constants/CourseResultsConstants.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.Constants
{
    public static class CourseResultsConstants
    {
        public const int ResponsesMaxPageSize = 50;
        /// <summary>Comentarios destacados en el PDF (todos van en el Excel).</summary>
        public const int PdfCommentsLimit = 12;

        public const string FormatExcel = "xlsx";
        public const string FormatPdf = "pdf";
        public const string ExcelContentType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        public const string PdfContentType = "application/pdf";

        public const string InvalidFormat = "Formato no válido: usa xlsx o pdf.";
        public const string NotEnoughResponses =
            "Aún no hay respuestas suficientes para mostrarlas sin romper el anonimato ({0} de {1}).";
    }
}
```

### `DTOs/CourseResultsDtos.cs`

```csharp
namespace DOCCB.Application.Features.Courses.Application.DTOs
{
    public class CourseResponsesQueryDto
    {
        /// <summary>Solo se aplica si los grupos se pueden mostrar sin romper el anonimato.</summary>
        public int? AssignmentId { get; set; }
        public bool WithComments { get; set; }
        public int Page { get; set; } = 1;
        public int PageSize { get; set; } = 10;
    }

    /// <summary>Una respuesta anónima, tal como se muestra.</summary>
    public class AnonymousResponseDto
    {
        /// <summary>Posición en la lista ("Respuesta 12"). No es un id ni sigue el orden de envío.</summary>
        public int Number { get; set; }
        /// <summary>null cuando el grupo no se puede mostrar sin romper el anonimato.</summary>
        public string? GroupName { get; set; }
        /// <summary>0 = sin calificar.</summary>
        public byte Satisfaction { get; set; }
        /// <summary>0 = sin calificar.</summary>
        public byte Usefulness { get; set; }
        public byte? KnowledgeBefore { get; set; }
        public byte? KnowledgeAfter { get; set; }
        public string? Comments { get; set; }
    }

    public class CourseResponsesPageDto
    {
        /// <summary>false = menos respuestas que el mínimo: Items va vacío.</summary>
        public bool Visible { get; set; }
        public int Responses { get; set; }
        public int MinimumResponses { get; set; }
        /// <summary>true = se puede filtrar y mostrar por grupo.</summary>
        public bool ByGroupAvailable { get; set; }
        /// <summary>Total con los filtros aplicados.</summary>
        public int TotalCount { get; set; }
        public List<AnonymousResponseDto> Items { get; set; } = [];
    }

    /// <summary>Un archivo listo para descargar.</summary>
    public sealed record CourseResultsFileDto(byte[] Content, string ContentType, string FileName);
}
```

---

## 5. Paso 3 — Los datos de los archivos

### `Exports/CourseResultsReport.cs`

Todo lo que necesitan el Excel y el PDF, ya leído y con las reglas de anonimato aplicadas.

```csharp
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Exports
{
    /// <param name="Progress">Avance por grupo y calificaciones (el mismo cálculo de la pantalla).</param>
    /// <param name="People">Quién está asignado y su estado.</param>
    /// <param name="Responses">Respuestas anónimas. Vacía si no hay suficientes.</param>
    /// <param name="ShowGroupInResponses">false = las respuestas van sin grupo (algún grupo no llega al mínimo).</param>
    /// <param name="GeneratedAt">Hora de Colombia.</param>
    public sealed record CourseResultsReport(
        CourseProgressDto Progress,
        IReadOnlyList<ResultsPersonRow> People,
        IReadOnlyList<AnonymousResponseRow> Responses,
        bool ShowGroupInResponses,
        DateTime GeneratedAt)
    {
        public int Total => Progress.Assignments.Sum(a => a.Total);
        public int Completed => Progress.Assignments.Sum(a => a.Completed);
        public int Overdue => Progress.Assignments.Sum(a => a.Overdue);
        public int Pending => Total - Completed;
        public double Percent => Total == 0 ? 0 : (double)Completed / Total;

        /// <summary>Nombre del grupo de cada asignación (o "Grupo sin nombre").</summary>
        public string GroupOf(int assignmentId) =>
            Progress.Assignments.FirstOrDefault(a => a.AssignmentId == assignmentId) is { GroupName.Length: > 0 } a
                ? a.GroupName
                : "Grupo sin nombre";
    }
}
```

---

## 6. Paso 4 — ⭐ El Excel: `Exports/CourseResultsExcelWriter.cs`

**Qué trae cada hoja:**

| Hoja | Qué tiene |
|---|---|
| **Resumen** | Título, cifras grandes (asignados, finalizaron, faltan, vencidos, respuestas) y una barra de avance hecha con bloques (`██████░░░░ 60 %`). Las calificaciones van con estrellas (`★★★★☆ 4,2`), la distribución de estrellas y de conocimiento con barras de datos de Excel, y al final "Cómo leer este archivo". |
| **Por grupo** | Una fila por grupo: fecha límite, avance con barra de datos de 0 % a 100 %, vencidos y, si el anonimato lo permite, las calificaciones del grupo. |
| **Personas** | Tabla con filtros: grupo, persona, correo, gerencia, estado (con color) y fecha de finalización. |
| **Respuestas (anónimas)** | Tabla con filtros: estrellas, conocimiento antes y después, diferencia (escala de color: gris si baja, amarillo si sube) y comentario. Sin nombre, sin fecha y en orden aleatorio. |

```csharp
using System.Globalization;
using ClosedXML.Excel;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Exports
{
    /// <summary>Libro de Excel de los resultados de un curso. Solo amarillos y grises, como el sistema.</summary>
    public static class CourseResultsExcelWriter
    {
        private static readonly CultureInfo Spanish = new("es-CO");
        private static readonly XLColor Yellow = XLColor.FromHtml("#F5C518");
        private static readonly XLColor YellowSoft = XLColor.FromHtml("#FFF8E1");
        private static readonly XLColor Dark = XLColor.FromHtml("#1F2937");
        private static readonly XLColor Gray = XLColor.FromHtml("#F3F4F6");
        private static readonly XLColor GrayBorder = XLColor.FromHtml("#E5E7EB");
        private static readonly XLColor Muted = XLColor.FromHtml("#6B7280");

        public static byte[] Write(CourseResultsReport report)
        {
            using var workbook = new XLWorkbook();
            workbook.Properties.Title = $"Resultados — {report.Progress.CourseName}";
            workbook.Style.Font.FontName = "Calibri";
            workbook.Style.Font.FontSize = 11;

            WriteSummary(workbook.Worksheets.Add("Resumen"), report);
            WriteGroups(workbook.Worksheets.Add("Por grupo"), report);
            WritePeople(workbook.Worksheets.Add("Personas"), report);
            WriteResponses(workbook.Worksheets.Add("Respuestas (anónimas)"), report);

            using var stream = new MemoryStream();
            workbook.SaveAs(stream);
            return stream.ToArray();
        }

        // ── Resumen ─────────────────────────────────────────────────────

        private static void WriteSummary(IXLWorksheet ws, CourseResultsReport report)
        {
            ws.ShowGridLines = false;
            ws.Column(1).Width = 3;
            ws.Columns(2, 7).Width = 18;

            // Título
            ws.Range("B2:G2").Merge().Value = "Resultados del curso";
            ws.Cell("B2").Style.Font.SetBold().Font.SetFontSize(20).Font.SetFontColor(Dark);
            ws.Range("B3:G3").Merge().Value = report.Progress.CourseName;
            ws.Cell("B3").Style.Font.SetFontSize(14).Font.SetBold();
            ws.Range("B4:G4").Merge().Value =
                $"Generado el {report.GeneratedAt.ToString("d 'de' MMMM 'de' yyyy, h:mm tt", Spanish)} · Las calificaciones son anónimas.";
            ws.Cell("B4").Style.Font.SetFontColor(Muted).Font.SetItalic();
            ws.Range("B2:G2").Style.Border.SetBottomBorder(XLBorderStyleValues.Thick).Border.SetBottomBorderColor(Yellow);

            // Cifras grandes
            var kpis = new (string Label, string Value)[]
            {
                ("Asignados", report.Total.ToString(Spanish)),
                ("Finalizaron", report.Completed.ToString(Spanish)),
                ("Faltan", report.Pending.ToString(Spanish)),
                ("Vencidos", report.Overdue.ToString(Spanish)),
                ("Avance", report.Percent.ToString("0%", Spanish)),
                ("Respuestas", report.Progress.Ratings.Responses.ToString(Spanish)),
            };

            for (var i = 0; i < kpis.Length; i++)
            {
                var value = ws.Cell(6, 2 + i);
                value.Value = kpis[i].Value;
                value.Style.Font.SetFontSize(22).Font.SetBold().Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center);
                value.Style.Fill.SetBackgroundColor(i == 1 ? YellowSoft : Gray);

                var label = ws.Cell(7, 2 + i);
                label.Value = kpis[i].Label;
                label.Style.Font.SetFontColor(Muted).Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center);
                label.Style.Fill.SetBackgroundColor(i == 1 ? YellowSoft : Gray);
            }

            // Barra de avance (texto: se ve igual en cualquier Excel)
            ws.Range("B9:G9").Merge().Value = $"{Blocks(report.Percent, 30)}  {report.Percent.ToString("0%", Spanish)} del curso finalizado";
            ws.Cell("B9").Style.Font.SetFontColor(XLColor.FromHtml("#B45309")).Font.SetFontSize(12);

            // Calificaciones
            var row = 11;
            Section(ws, row++, "Calificaciones (anónimas)");
            var ratings = report.Progress.Ratings;

            if (!ratings.Visible)
            {
                ws.Range(row, 2, row, 7).Merge().Value =
                    string.Format(CourseResultsConstants.NotEnoughResponses, ratings.Responses, ratings.MinimumResponses);
                ws.Cell(row, 2).Style.Font.SetFontColor(Muted);
                row += 2;
            }
            else
            {
                Header(ws, row++, "Pregunta", "Promedio", "Visual", "Respondieron", "Sin responder");
                RatingRow(ws, row++, "Calidad del espacio de formación", ratings.SatisfactionAverage, 5, ratings.SatisfactionDistribution);
                RatingRow(ws, row++, "Utilidad para el rol", ratings.UsefulnessAverage, 5, ratings.UsefulnessDistribution);
                RatingRow(ws, row++, "Conocimiento antes", ratings.KnowledgeBeforeAverage, 10, ratings.KnowledgeBeforeDistribution);
                RatingRow(ws, row++, "Conocimiento después", ratings.KnowledgeAfterAverage, 10, ratings.KnowledgeAfterDistribution);

                if (ratings.KnowledgeBeforeAverage is { } before && ratings.KnowledgeAfterAverage is { } after)
                {
                    var gain = after - before;
                    ws.Range(row, 2, row, 7).Merge().Value =
                        $"Ganancia de conocimiento: {(gain >= 0 ? "+" : "")}{gain.ToString("0.0", Spanish)} puntos sobre 10";
                    ws.Cell(row, 2).Style.Font.SetBold().Fill.SetBackgroundColor(gain >= 0 ? YellowSoft : Gray);
                    row++;
                }

                // Distribución de estrellas (5 a 1 y "sin calificar")
                row++;
                Section(ws, row++, "¿Cuántas estrellas dieron?");
                Header(ws, row++, "Estrellas", "Calidad", "% calidad", "Utilidad", "% utilidad");
                var starsStart = row;
                for (var stars = 5; stars >= 0; stars--)
                {
                    ws.Cell(row, 2).Value = stars == 0 ? "Sin calificar" : Stars(stars, 5);
                    DistributionCells(ws, row, 3, ratings.SatisfactionDistribution, stars);
                    DistributionCells(ws, row, 5, ratings.UsefulnessDistribution, stars);
                    row++;
                }

                DataBars(ws.Range(starsStart, 3, row - 1, 3));
                DataBars(ws.Range(starsStart, 5, row - 1, 5));

                // Distribución de conocimiento (1 a 10)
                row++;
                Section(ws, row++, "Nivel de conocimiento (1 a 10)");
                Header(ws, row++, "Nivel", "Antes", "% antes", "Después", "% después");
                var levelStart = row;
                for (var level = 10; level >= 1; level--)
                {
                    ws.Cell(row, 2).Value = level;
                    DistributionCells(ws, row, 3, ratings.KnowledgeBeforeDistribution, level);
                    DistributionCells(ws, row, 5, ratings.KnowledgeAfterDistribution, level);
                    row++;
                }

                DataBars(ws.Range(levelStart, 3, row - 1, 3));
                DataBars(ws.Range(levelStart, 5, row - 1, 5));
            }

            // Cómo leer
            row++;
            Section(ws, row++, "Cómo leer este archivo");
            foreach (var line in new[]
            {
                "• Por grupo: el avance de cada grupo (grupo + fecha límite).",
                "• Personas: quién finalizó, quién falta y quién venció. Usa los filtros de la tabla.",
                "• Respuestas (anónimas): lo que respondió cada persona, sin nombre, sin fecha y en orden aleatorio.",
                "• Las estrellas en 0 significan que la persona no calificó esa pregunta: no cuentan en el promedio.",
            })
            {
                ws.Range(row, 2, row, 7).Merge().Value = line;
                ws.Cell(row, 2).Style.Font.SetFontColor(Muted);
                row++;
            }

            ws.PageSetup.PageOrientation = XLPageOrientation.Portrait;
            ws.PageSetup.FitToPages(1, 0);
        }

        // ── Por grupo ───────────────────────────────────────────────────

        private static void WriteGroups(IXLWorksheet ws, CourseResultsReport report)
        {
            var showRatings = report.ShowGroupInResponses;
            var headers = new List<string> { "Grupo", "Fecha límite", "Asignados", "Finalizaron", "Faltan", "Vencidos", "Avance", "Sin usuario" };
            if (showRatings)
            {
                headers.AddRange(["Calidad (1-5)", "Utilidad (1-5)", "Respuestas"]);
            }

            Header(ws, 1, [.. headers], firstColumn: 1);

            var row = 2;
            foreach (var a in report.Progress.Assignments)
            {
                ws.Cell(row, 1).Value = string.IsNullOrWhiteSpace(a.GroupName) ? "Grupo sin nombre" : a.GroupName;
                ws.Cell(row, 2).Value = a.DueDate.ToDateTime(TimeOnly.MinValue);
                ws.Cell(row, 2).Style.DateFormat.Format = "dd/mm/yyyy";
                ws.Cell(row, 3).Value = a.Total;
                ws.Cell(row, 4).Value = a.Completed;
                ws.Cell(row, 5).Value = a.Total - a.Completed;
                ws.Cell(row, 6).Value = a.Overdue;
                ws.Cell(row, 7).Value = a.Total == 0 ? 0 : (double)a.Completed / a.Total;
                ws.Cell(row, 7).Style.NumberFormat.Format = "0%";
                ws.Cell(row, 8).Value = a.WithoutUser;

                if (showRatings)
                {
                    SetAverage(ws.Cell(row, 9), a.Ratings?.SatisfactionAverage);
                    SetAverage(ws.Cell(row, 10), a.Ratings?.UsefulnessAverage);
                    ws.Cell(row, 11).Value = a.Ratings?.Responses ?? 0;
                }

                if (a.Overdue > 0)
                {
                    ws.Cell(row, 6).Style.Font.SetBold().Font.SetFontColor(XLColor.White).Fill.SetBackgroundColor(Dark);
                }

                row++;
            }

            if (row > 2)
            {
                // Avance de 0 % a 100 % (fijo: no relativo al mejor grupo).
                ws.Range(2, 7, row - 1, 7).AddConditionalFormat()
                    .DataBar(Yellow)
                    .Minimum(XLCFContentType.Number, 0)
                    .Maximum(XLCFContentType.Number, 1);

                ws.Range(1, 1, row - 1, headers.Count).CreateTable("Grupos").Theme = XLTableTheme.TableStyleLight1;
            }

            ws.SheetView.FreezeRows(1);
            ws.Columns().AdjustToContents();
            ws.Column(7).Width = 22;
        }

        // ── Personas ────────────────────────────────────────────────────

        private static void WritePeople(IXLWorksheet ws, CourseResultsReport report)
        {
            Header(ws, 1, ["Grupo", "Fecha límite", "Persona", "Correo", "Gerencia", "Estado", "Finalizó el"], firstColumn: 1);
            var dueByAssignment = report.Progress.Assignments.ToDictionary(a => a.AssignmentId, a => a.DueDate);

            var row = 2;
            foreach (var person in report.People)
            {
                var status = person.Completed ? "Finalizado" : person.IsOverdue ? "Vencido" : "Pendiente";

                ws.Cell(row, 1).Value = report.GroupOf(person.AssignmentId);
                if (dueByAssignment.TryGetValue(person.AssignmentId, out var due))
                {
                    ws.Cell(row, 2).Value = due.ToDateTime(TimeOnly.MinValue);
                    ws.Cell(row, 2).Style.DateFormat.Format = "dd/mm/yyyy";
                }

                ws.Cell(row, 3).Value = person.DisplayName;
                ws.Cell(row, 4).Value = person.Email;
                ws.Cell(row, 5).Value = person.Management ?? "—";
                ws.Cell(row, 6).Value = status;
                if (person.CompletedDate is { } completed)
                {
                    ws.Cell(row, 7).Value = completed;
                    ws.Cell(row, 7).Style.DateFormat.Format = "dd/mm/yyyy";
                }

                var statusCell = ws.Cell(row, 6).Style.Font.SetBold();
                if (status == "Finalizado") statusCell.Fill.SetBackgroundColor(YellowSoft);
                else if (status == "Vencido") statusCell.Font.SetFontColor(XLColor.White).Fill.SetBackgroundColor(Dark);
                else statusCell.Fill.SetBackgroundColor(Gray);

                row++;
            }

            if (row > 2)
            {
                ws.Range(1, 1, row - 1, 7).CreateTable("Personas").Theme = XLTableTheme.TableStyleLight1;
            }

            ws.SheetView.FreezeRows(1);
            ws.Columns().AdjustToContents();
        }

        // ── Respuestas (anónimas) ───────────────────────────────────────

        private static void WriteResponses(IXLWorksheet ws, CourseResultsReport report)
        {
            ws.Range("A1:J1").Merge().Value = "Respuestas anónimas: sin nombre, sin fecha y en orden aleatorio.";
            ws.Cell("A1").Style.Font.SetItalic().Font.SetFontColor(Muted);

            var ratings = report.Progress.Ratings;
            if (!ratings.Visible)
            {
                ws.Range("A3:J3").Merge().Value =
                    string.Format(CourseResultsConstants.NotEnoughResponses, ratings.Responses, ratings.MinimumResponses);
                return;
            }

            var headers = new List<string> { "N.°" };
            if (report.ShowGroupInResponses) headers.Add("Grupo");
            headers.AddRange(["Calidad", "Calidad (1-5)", "Utilidad", "Utilidad (1-5)", "Conocimiento antes", "Conocimiento después", "Diferencia", "Comentario"]);
            Header(ws, 3, [.. headers], firstColumn: 1);

            var row = 4;
            var number = 1;
            foreach (var r in report.Responses)
            {
                var col = 1;
                ws.Cell(row, col++).Value = number++;
                if (report.ShowGroupInResponses) ws.Cell(row, col++).Value = r.GroupName ?? "Grupo sin nombre";

                ws.Cell(row, col++).Value = r.Satisfaction == 0 ? "Sin calificar" : Stars(r.Satisfaction, 5);
                SetScore(ws.Cell(row, col++), r.Satisfaction == 0 ? null : r.Satisfaction);
                ws.Cell(row, col++).Value = r.Usefulness == 0 ? "Sin calificar" : Stars(r.Usefulness, 5);
                SetScore(ws.Cell(row, col++), r.Usefulness == 0 ? null : r.Usefulness);
                SetScore(ws.Cell(row, col++), r.KnowledgeBefore);
                SetScore(ws.Cell(row, col++), r.KnowledgeAfter);
                SetScore(ws.Cell(row, col++), r.KnowledgeBefore is { } before && r.KnowledgeAfter is { } after ? after - before : null);

                var comment = ws.Cell(row, col);
                comment.Value = r.Comments ?? string.Empty;
                comment.Style.Alignment.SetWrapText(true).Alignment.SetVertical(XLAlignmentVerticalValues.Top);
                row++;
            }

            var starColumns = report.ShowGroupInResponses ? new[] { 3, 5 } : new[] { 2, 4 };
            foreach (var column in starColumns)
            {
                ws.Column(column).Style.Font.SetFontColor(XLColor.FromHtml("#B45309"));
            }

            if (row > 4)
            {
                var diffColumn = headers.Count - 1;
                // Diferencia: gris si bajó, blanco si igual, amarillo si subió.
                ws.Range(4, diffColumn, row - 1, diffColumn).AddConditionalFormat()
                    .ColorScale()
                    .Minimum(XLCFContentType.Number, -9, XLColor.FromHtml("#9CA3AF"))
                    .Midpoint(XLCFContentType.Number, 0, XLColor.White)
                    .Maximum(XLCFContentType.Number, 9, Yellow);

                ws.Range(3, 1, row - 1, headers.Count).CreateTable("Respuestas").Theme = XLTableTheme.TableStyleLight1;
            }

            ws.SheetView.FreezeRows(3);
            ws.Columns().AdjustToContents();
            ws.Column(headers.Count).Width = 70; // comentario
        }

        // ── Ayudantes ───────────────────────────────────────────────────

        private static void Section(IXLWorksheet ws, int row, string title)
        {
            ws.Range(row, 2, row, 7).Merge().Value = title;
            ws.Cell(row, 2).Style.Font.SetBold().Font.SetFontSize(13).Font.SetFontColor(Dark);
            ws.Range(row, 2, row, 7).Style.Border.SetBottomBorder(XLBorderStyleValues.Thin).Border.SetBottomBorderColor(Yellow);
        }

        private static void Header(IXLWorksheet ws, int row, string[] titles, int firstColumn = 2)
        {
            for (var i = 0; i < titles.Length; i++)
            {
                var cell = ws.Cell(row, firstColumn + i);
                cell.Value = titles[i];
                cell.Style.Font.SetBold().Font.SetFontColor(XLColor.White).Fill.SetBackgroundColor(Dark);
                cell.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center).Alignment.SetWrapText(true);
            }
        }

        private static void Header(IXLWorksheet ws, int row, params string[] titles) => Header(ws, row, titles, firstColumn: 2);

        private static void RatingRow(IXLWorksheet ws, int row, string label, double? average, int max, int[]? distribution)
        {
            var answered = distribution?.Skip(1).Sum() ?? 0;
            ws.Cell(row, 2).Value = label;
            SetAverage(ws.Cell(row, 3), average);
            ws.Cell(row, 4).Value = average is { } value
                ? max == 5 ? Stars((int)Math.Round(value), 5) : Blocks(value / max, 10)
                : "—";
            ws.Cell(row, 4).Style.Font.SetFontColor(XLColor.FromHtml("#B45309"));
            ws.Cell(row, 5).Value = answered;
            ws.Cell(row, 6).Value = distribution?[0] ?? 0;
            ws.Range(row, 2, row, 6).Style.Border.SetBottomBorder(XLBorderStyleValues.Hair).Border.SetBottomBorderColor(GrayBorder);
        }

        /// <summary>Cantidad y porcentaje de un valor de la distribución (sobre todas las respuestas).</summary>
        private static void DistributionCells(IXLWorksheet ws, int row, int column, int[]? distribution, int index)
        {
            var total = distribution?.Sum() ?? 0;
            var count = distribution is not null && index < distribution.Length ? distribution[index] : 0;
            ws.Cell(row, column).Value = count;
            ws.Cell(row, column + 1).Value = total == 0 ? 0 : (double)count / total;
            ws.Cell(row, column + 1).Style.NumberFormat.Format = "0%";
        }

        private static void DataBars(IXLRange range) =>
            range.AddConditionalFormat().DataBar(Yellow).LowestValue().HighestValue();

        private static void SetAverage(IXLCell cell, double? value)
        {
            if (value is { } number)
            {
                cell.Value = number;
                cell.Style.NumberFormat.Format = "0.0";
            }
            else
            {
                cell.Value = "—";
            }

            cell.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center);
        }

        private static void SetScore(IXLCell cell, int? value)
        {
            if (value is { } number) cell.Value = number;
            cell.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center);
        }

        /// <summary>★★★★☆</summary>
        private static string Stars(int value, int max) => new string('★', value) + new string('☆', max - value);

        /// <summary>██████░░░░ para una fracción de 0 a 1.</summary>
        private static string Blocks(double fraction, int width)
        {
            var filled = (int)Math.Round(Math.Clamp(fraction, 0, 1) * width);
            return new string('█', filled) + new string('░', width - filled);
        }
    }
}
```

> **Las barras de datos y la escala de color** son formato condicional de Excel: se actualizan si alguien filtra o cambia un número, y se ven igual en Excel de escritorio, en la web y en Google Sheets.

---

## 7. Paso 5 — ⭐ El PDF: `Exports/CourseResultsPdfWriter.cs`

**Un informe para leer en dos minutos:**
1. Las cifras grandes y la barra de avance del curso.
2. "Por grupo": una tabla con la barra de avance de cada grupo.
3. Las calificaciones, con barras de estrellas y el conocimiento antes → después.
4. Los comentarios destacados (los primeros 12 de la lista aleatoria; todos van en el Excel).

```csharp
using System.Globalization;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using QuestPDF.Fluent;
using QuestPDF.Helpers;
using QuestPDF.Infrastructure;

namespace DOCCB.Application.Features.Courses.Application.Exports
{
    /// <summary>Informe en PDF de los resultados de un curso, para compartir.</summary>
    public static class CourseResultsPdfWriter
    {
        private static readonly CultureInfo Spanish = new("es-CO");
        private const string Yellow = "#F5C518";
        private const string YellowSoft = "#FFF8E1";
        private const string Amber = "#B45309";
        private const string Dark = "#1F2937";
        private const string Gray = "#F3F4F6";
        private const string Track = "#E5E7EB";
        private const string Muted = "#6B7280";

        public static byte[] Write(CourseResultsReport report) =>
            Document.Create(container => container.Page(page =>
            {
                page.Size(PageSizes.Letter);
                page.Margin(36);
                page.DefaultTextStyle(x => x.FontFamily("Arial").FontSize(10).FontColor(Dark));

                page.Header().Element(c => ComposeHeader(c, report));
                page.Content().PaddingTop(12).Element(c => ComposeContent(c, report));
                page.Footer().AlignCenter().Text(text =>
                {
                    text.DefaultTextStyle(x => x.FontSize(8).FontColor(Muted));
                    text.Span("Calificaciones anónimas: sin nombre ni fecha · Página ");
                    text.CurrentPageNumber();
                    text.Span(" de ");
                    text.TotalPages();
                });
            }))
            .GeneratePdf();

        private static void ComposeHeader(IContainer container, CourseResultsReport report) =>
            container.BorderBottom(3).BorderColor(Yellow).PaddingBottom(8).Column(column =>
            {
                column.Item().Text("Resultados del curso").FontSize(9).Bold().FontColor(Amber);
                column.Item().Text(report.Progress.CourseName).FontSize(18).Bold();
                column.Item().Text($"Generado el {report.GeneratedAt.ToString("d 'de' MMMM 'de' yyyy, h:mm tt", Spanish)}")
                    .FontSize(9).FontColor(Muted);
            });

        private static void ComposeContent(IContainer container, CourseResultsReport report) =>
            container.Column(column =>
            {
                column.Spacing(16);

                // Cifras
                column.Item().Row(row =>
                {
                    row.Spacing(8);
                    Kpi(row.RelativeItem(), report.Total, "Asignados", Gray);
                    Kpi(row.RelativeItem(), report.Completed, "Finalizaron", YellowSoft);
                    Kpi(row.RelativeItem(), report.Pending, "Faltan", Gray);
                    Kpi(row.RelativeItem(), report.Overdue, "Vencidos", Gray);
                    Kpi(row.RelativeItem(), report.Progress.Ratings.Responses, "Respuestas", Gray);
                });

                column.Item().Column(progress =>
                {
                    progress.Spacing(4);
                    progress.Item().Element(c => Bar(c, report.Percent, 12));
                    progress.Item().Text($"{report.Percent.ToString("0%", Spanish)} del curso finalizado").FontSize(9).FontColor(Muted);
                });

                // Por grupo
                column.Item().Element(c => Title(c, "Por grupo"));
                column.Item().Table(table =>
                {
                    table.ColumnsDefinition(columns =>
                    {
                        columns.RelativeColumn(3);
                        columns.RelativeColumn(1.4f);
                        columns.RelativeColumn(3);
                        columns.RelativeColumn(1.3f);
                        columns.RelativeColumn(1);
                    });

                    table.Header(header =>
                    {
                        foreach (var title in new[] { "Grupo", "Fecha límite", "Avance", "Finalizaron", "Vencidos" })
                        {
                            header.Cell().Background(Dark).Padding(5).Text(title).FontColor("#FFFFFF").FontSize(9).Bold();
                        }
                    });

                    foreach (var a in report.Progress.Assignments)
                    {
                        var percent = a.Total == 0 ? 0 : (double)a.Completed / a.Total;
                        table.Cell().Element(Cell).Text(string.IsNullOrWhiteSpace(a.GroupName) ? "Grupo sin nombre" : a.GroupName);
                        table.Cell().Element(Cell).Text(a.DueDate.ToString("d MMM yyyy", Spanish));
                        table.Cell().Element(Cell).Row(row =>
                        {
                            row.RelativeItem().AlignMiddle().Element(c => Bar(c, percent, 8));
                            row.ConstantItem(34).AlignRight().Text(percent.ToString("0%", Spanish)).FontSize(9);
                        });
                        table.Cell().Element(Cell).Text($"{a.Completed} de {a.Total}");
                        table.Cell().Element(Cell).Text(a.Overdue.ToString(Spanish)).Bold().FontColor(a.Overdue > 0 ? Dark : Muted);
                    }
                });

                // Calificaciones
                column.Item().Element(c => Title(c, "Calificaciones (anónimas)"));
                var ratings = report.Progress.Ratings;
                if (!ratings.Visible)
                {
                    column.Item().Background(Gray).Padding(10).Text(
                        string.Format(CourseResultsConstants.NotEnoughResponses, ratings.Responses, ratings.MinimumResponses))
                        .FontColor(Muted);
                }
                else
                {
                    column.Item().Row(row =>
                    {
                        row.Spacing(16);
                        row.RelativeItem().Element(c => StarsBlock(c, "Calidad del espacio de formación", ratings.SatisfactionAverage, ratings.SatisfactionDistribution));
                        row.RelativeItem().Element(c => StarsBlock(c, "Utilidad para el rol", ratings.UsefulnessAverage, ratings.UsefulnessDistribution));
                    });

                    column.Item().Element(c => KnowledgeBlock(c, ratings));
                }

                // Comentarios
                var comments = report.Responses
                    .Select(r => r.Comments)
                    .Where(text => !string.IsNullOrWhiteSpace(text))
                    .Take(CourseResultsConstants.PdfCommentsLimit)
                    .ToList();

                if (comments.Count > 0)
                {
                    column.Item().Element(c => Title(c, "Comentarios"));
                    foreach (var comment in comments)
                    {
                        column.Item().BorderLeft(3).BorderColor(Yellow).Background(Gray).Padding(8).Text(comment!).Italic();
                    }

                    column.Item().Text("Todos los comentarios están en la hoja «Respuestas (anónimas)» del Excel.").FontSize(8).FontColor(Muted);
                }
            });

        // ── Piezas ──────────────────────────────────────────────────────

        private static void Kpi(IContainer container, int value, string label, string background) =>
            container.Background(background).Padding(10).Column(column =>
            {
                column.Item().AlignCenter().Text(value.ToString(Spanish)).FontSize(20).Bold();
                column.Item().AlignCenter().Text(label).FontSize(8).FontColor(Muted);
            });

        private static void Title(IContainer container, string text) =>
            container.BorderBottom(1).BorderColor(Track).PaddingBottom(3).Text(text).FontSize(12).Bold();

        private static IContainer Cell(IContainer container) =>
            container.BorderBottom(1).BorderColor(Track).PaddingVertical(5).PaddingHorizontal(4);

        /// <summary>Barra amarilla sobre gris, de 0 a 1.</summary>
        private static void Bar(IContainer container, double fraction, float height)
        {
            var filled = (float)Math.Clamp(fraction, 0, 1);
            container.Height(height).Row(row =>
            {
                if (filled > 0) row.RelativeItem(filled).Background(Yellow);
                if (filled < 1) row.RelativeItem(1 - filled).Background(Track);
            });
        }

        /// <summary>Promedio grande y barras de 5 a 1 estrellas.</summary>
        private static void StarsBlock(IContainer container, string label, double? average, int[]? distribution) =>
            container.Column(column =>
            {
                column.Spacing(3);
                column.Item().Text(label).Bold();
                column.Item().Text(text =>
                {
                    text.Span(average?.ToString("0.0", Spanish) ?? "—").FontSize(20).Bold().FontColor(Amber);
                    text.Span(" / 5").FontColor(Muted);
                });

                var answered = distribution?.Skip(1).Sum() ?? 0;
                for (var stars = 5; stars >= 1; stars--)
                {
                    var count = distribution?[stars] ?? 0;
                    column.Item().Row(row =>
                    {
                        row.ConstantItem(42).Text($"{stars} ★").FontSize(8).FontColor(Muted);
                        row.RelativeItem().AlignMiddle().Element(c => Bar(c, answered == 0 ? 0 : (double)count / answered, 6));
                        row.ConstantItem(24).AlignRight().Text(count.ToString(Spanish)).FontSize(8);
                    });
                }

                if (distribution?[0] is > 0 and var skipped)
                {
                    column.Item().Text($"{skipped} sin calificar").FontSize(8).FontColor(Muted);
                }
            });

        /// <summary>"Antes 4,1 → después 7,8 (+3,7)".</summary>
        private static void KnowledgeBlock(IContainer container, RatingSummaryDto ratings) =>
            container.Background(Gray).Padding(10).Row(row =>
            {
                row.RelativeItem().Column(c =>
                {
                    c.Item().Text("Conocimiento antes").FontSize(8).FontColor(Muted);
                    c.Item().Text($"{ratings.KnowledgeBeforeAverage?.ToString("0.0", Spanish) ?? "—"} / 10").FontSize(16).Bold();
                });
                row.ConstantItem(30).AlignMiddle().AlignCenter().Text("→").FontSize(16).FontColor(Muted);
                row.RelativeItem().Column(c =>
                {
                    c.Item().Text("Conocimiento después").FontSize(8).FontColor(Muted);
                    c.Item().Text($"{ratings.KnowledgeAfterAverage?.ToString("0.0", Spanish) ?? "—"} / 10").FontSize(16).Bold();
                });

                if (ratings.KnowledgeBeforeAverage is { } before && ratings.KnowledgeAfterAverage is { } after)
                {
                    var gain = after - before;
                    row.ConstantItem(90).AlignMiddle().Background(gain >= 0 ? Yellow : Dark).Padding(6).AlignCenter()
                        .Text($"{(gain >= 0 ? "+" : "")}{gain.ToString("0.0", Spanish)}")
                        .FontSize(14).Bold().FontColor(gain >= 0 ? Dark : "#FFFFFF");
                }
            });
    }
}
```

> **La licencia de QuestPDF** ya está configurada en `Program.cs` (`LicenseType.Community`), igual que para el certificado de cesantías.
>
> **La fuente** es Arial, la misma del certificado. El símbolo ★ de las barras va en tamaño pequeño; si el servidor no lo tiene, QuestPDF usa una fuente de respaldo.

---

## 8. Paso 6 — El servicio

### `Interfaces/ICourseResultsService.cs`

```csharp
using DOCCB.Application.Features.Courses.Application.DTOs;

namespace DOCCB.Application.Features.Courses.Application.Interfaces
{
    public interface ICourseResultsService
    {
        /// <summary>Respuestas anónimas del curso, por páginas. Vacía si no hay suficientes.</summary>
        Task<CourseResult<CourseResponsesPageDto>> GetResponsesAsync(int courseId, CourseResponsesQueryDto dto, CancellationToken ct = default);

        /// <summary>Los resultados en Excel ("xlsx", por defecto) o PDF ("pdf").</summary>
        Task<CourseResult<CourseResultsFileDto>> ExportAsync(int courseId, string? format, CancellationToken ct = default);
    }
}
```

### `Services/CourseResultsService.cs`

```csharp
using System.Text.RegularExpressions;
using DOCCB.Application.Contracts.Persistence;
using DOCCB.Application.Features.Courses.Application.Constants;
using DOCCB.Application.Features.Courses.Application.DTOs;
using DOCCB.Application.Features.Courses.Application.Exports;
using DOCCB.Application.Features.Courses.Application.Helpers;
using DOCCB.Application.Features.Courses.Application.Interfaces;

namespace DOCCB.Application.Features.Courses.Application.Services
{
    public class CourseResultsService(
        ICourseCompletionService completionService,
        ICourseCompletionRepository repository,
        TimeProvider timeProvider) : ICourseResultsService
    {
        private static readonly TimeZoneInfo Zone = TimeZoneInfo.FindSystemTimeZoneById(CourseConstants.BusinessTimeZoneId);

        public async Task<CourseResult<CourseResponsesPageDto>> GetResponsesAsync(
            int courseId, CourseResponsesQueryDto dto, CancellationToken ct = default)
        {
            var minimum = CompletionConstants.MinimumResponsesForSummary;
            var buckets = await repository.GetRatingBucketsAsync(courseId, ct);
            var responses = buckets.Sum(b => b.Count);
            var byGroup = RatingSummaryBuilder.CanShowPerAssignment(buckets, minimum);

            var page = new CourseResponsesPageDto
            {
                Visible = responses >= minimum,
                Responses = responses,
                MinimumResponses = minimum,
                ByGroupAvailable = byGroup,
            };

            // Con pocas respuestas se sabría de quién son: solo el conteo.
            if (!page.Visible) return CourseResult<CourseResponsesPageDto>.Ok(page);

            var pageNumber = Math.Max(1, dto.Page);
            var pageSize = Math.Clamp(dto.PageSize, 1, CourseResultsConstants.ResponsesMaxPageSize);
            // El filtro por grupo solo vale si todos los grupos llegan al mínimo.
            var assignmentId = byGroup ? dto.AssignmentId : null;

            var (items, total) = await repository.GetResponsesAsync(
                courseId, assignmentId, dto.WithComments, (pageNumber - 1) * pageSize, pageSize, ct);

            page.TotalCount = total;
            page.Items = items
                .Select((r, i) => new AnonymousResponseDto
                {
                    Number = (pageNumber - 1) * pageSize + i + 1,
                    GroupName = byGroup ? r.GroupName ?? "Grupo sin nombre" : null,
                    Satisfaction = r.Satisfaction,
                    Usefulness = r.Usefulness,
                    KnowledgeBefore = r.KnowledgeBefore,
                    KnowledgeAfter = r.KnowledgeAfter,
                    Comments = r.Comments,
                })
                .ToList();

            return CourseResult<CourseResponsesPageDto>.Ok(page);
        }

        public async Task<CourseResult<CourseResultsFileDto>> ExportAsync(int courseId, string? format, CancellationToken ct = default)
        {
            var kind = string.IsNullOrWhiteSpace(format) ? CourseResultsConstants.FormatExcel : format.Trim().ToLowerInvariant();
            if (kind is not (CourseResultsConstants.FormatExcel or CourseResultsConstants.FormatPdf))
                return CourseResult<CourseResultsFileDto>.Fail(CourseResultStatus.Invalid, CourseResultsConstants.InvalidFormat);

            // El mismo cálculo de la pantalla (avance y calificaciones con anonimato).
            var progressResult = await completionService.GetProgressAsync(courseId, ct);
            if (progressResult.Status != CourseResultStatus.Ok || progressResult.Response.Response is not { } progress)
                return CourseResult<CourseResultsFileDto>.Fail(CourseResultStatus.NotFound, CourseConstants.CourseNotFound);

            var now = TimeZoneInfo.ConvertTime(timeProvider.GetUtcNow(), Zone).DateTime;
            var today = DateOnly.FromDateTime(now);
            var people = await repository.GetResultsPeopleAsync(courseId, today, ct);
            var buckets = await repository.GetRatingBucketsAsync(courseId, ct);

            var responses = progress.Ratings.Visible
                ? (await repository.GetResponsesAsync(courseId, null, false, 0, int.MaxValue, ct)).Items
                : [];

            var report = new CourseResultsReport(
                progress,
                people,
                responses,
                RatingSummaryBuilder.CanShowPerAssignment(buckets, CompletionConstants.MinimumResponsesForSummary),
                now);

            var baseName = $"Resultados_{FileSafe(progress.CourseName)}_{today:yyyy-MM-dd}";

            var file = kind == CourseResultsConstants.FormatPdf
                ? new CourseResultsFileDto(CourseResultsPdfWriter.Write(report), CourseResultsConstants.PdfContentType, $"{baseName}.pdf")
                : new CourseResultsFileDto(CourseResultsExcelWriter.Write(report), CourseResultsConstants.ExcelContentType, $"{baseName}.xlsx");

            return CourseResult<CourseResultsFileDto>.Ok(file);
        }

        /// <summary>"Seguridad en plataforma / 2026" → "Seguridad_en_plataforma_2026" (máximo 60).</summary>
        private static string FileSafe(string name)
        {
            var clean = Regex.Replace(name, @"[^\p{L}\p{N}]+", "_").Trim('_');
            return clean.Length <= 60 ? clean : clean[..60];
        }
    }
}
```

> **Fechas en el archivo:**
> - La fecha de finalización de la hoja "Personas" es la guardada (UTC).
> - El nombre del archivo y "Generado el…" usan la hora de Colombia.

### Registro

`ApplicationServiceRegistration.cs`, junto a `ICourseCompletionService`:

```csharp
services.AddScoped<ICourseResultsService, CourseResultsService>();
```

---

## 9. Paso 7 — Controlador y CORS

### `ApiResponseConstants.cs` ✏️

```csharp
public const string GetCourseResponsesErrorMessage = "No se pudieron cargar las respuestas del curso.";
public const string ExportCourseResultsErrorMessage = "No se pudo exportar los resultados del curso.";
```

### `CoursesController.cs` ✏️

**1. Dependencia:** agrega `ICourseResultsService resultsService` al constructor y su campo `_resultsService`.

**2. Las dos acciones**, con la misma forma de `GetAssignments`:

```csharp
/// <summary>Respuestas anónimas del formulario de finalización.</summary>
[HttpGet("{id:int}/responses")]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> GetResponses(
    [FromRoute] int id,
    [FromQuery] CourseResponsesQueryDto query,
    CancellationToken ct)
{
    try
    {
        var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
        if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
        {
            return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
        }

        if (id <= 0)
        {
            return BadRequest();
        }

        var result = await _resultsService.GetResponsesAsync(id, query, ct);
        return this.ToActionResult(result);
    }
    catch (ArgumentException ex)
    {
        return BadRequest(new { message = ApiResponseConstants.GetCourseResponsesErrorMessage, error = ex.Message });
    }
    catch (UnauthorizedAccessException)
    {
        return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
    }
    catch (Exception)
    {
        return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.GetCourseResponsesErrorMessage });
    }
}

/// <summary>Descarga los resultados: ?format=xlsx (por defecto) o ?format=pdf.</summary>
[HttpGet("{id:int}/results/export")]
[ProducesResponseType(StatusCodes.Status200OK)]
[ProducesResponseType(StatusCodes.Status400BadRequest)]
[ProducesResponseType(StatusCodes.Status401Unauthorized)]
[ProducesResponseType(StatusCodes.Status404NotFound)]
[ProducesResponseType(StatusCodes.Status500InternalServerError)]
public async Task<IActionResult> ExportResults(
    [FromRoute] int id,
    [FromQuery] string? format,
    CancellationToken ct)
{
    try
    {
        var authenticatedUserInfo = MicrosoftUserAuthenticatorHelper.GetAuthenticatedUserInfo(User);
        if (string.IsNullOrEmpty(authenticatedUserInfo.Email))
        {
            return Unauthorized(new { message = ApiResponseConstants.NotAuthenticatedUserMessage });
        }

        if (id <= 0)
        {
            return BadRequest();
        }

        var result = await _resultsService.ExportAsync(id, format, ct);
        if (result.Status == CourseResultStatus.Ok)
        {
            var file = result.Response.Response;
            return File(file.Content, file.ContentType, file.FileName);
        }

        return this.ToActionResult(result);
    }
    catch (ArgumentException ex)
    {
        return BadRequest(new { message = ApiResponseConstants.ExportCourseResultsErrorMessage, error = ex.Message });
    }
    catch (UnauthorizedAccessException)
    {
        return Unauthorized(new { message = ApiResponseConstants.UnauthorizedUserMessage });
    }
    catch (Exception)
    {
        return StatusCode(StatusCodes.Status500InternalServerError, new { message = ApiResponseConstants.ExportCourseResultsErrorMessage });
    }
}
```

### `Program.cs` ✏️ — que el navegador pueda leer el nombre del archivo

```csharp
app.UseCors(builder =>
    builder.WithOrigins(allowedOrigins)
           .AllowAnyHeader()
           .AllowAnyMethod()
           .WithExposedHeaders("Content-Disposition"));
```

> Sin esto, el frontend no ve el nombre que arma la API y usa uno propio.

---

## 10. Contrato

**`GET /api/courses/{id}/responses?assignmentId=&withComments=false&page=1&pageSize=10`**

```json
{
  "visible": true, "responses": 42, "minimumResponses": 3, "byGroupAvailable": true, "totalCount": 42,
  "items": [
    { "number": 1, "groupName": "Operaciones turno A", "satisfaction": 4, "usefulness": 0,
      "knowledgeBefore": 3, "knowledgeAfter": 8, "comments": "Muy práctico." }
  ]
}
```

- Con menos respuestas que el mínimo: `visible: false` e `items: []`.
- Con `byGroupAvailable: false`: `groupName` va en `null` y `assignmentId` se ignora.

**`GET /api/courses/{id}/results/export?format=xlsx|pdf`** devuelve el archivo con `Content-Disposition: attachment; filename=Resultados_<curso>_<fecha>.xlsx`. Si el formato no es válido, 400 con "Formato no válido: usa xlsx o pdf.".

---

## 11. Pruebas

**Respuestas**
- **Curso con 2 respuestas:** `visible: false`, sin `items`.
- **Curso con 10 respuestas en 2 grupos de 5:**
  - `byGroupAvailable: true`, cada respuesta con su grupo, y `assignmentId` filtra.
- **Uno de los grupos tiene solo 2 respuestas:**
  - `byGroupAvailable: false` y `groupName: null`.
  - Pedir `assignmentId` devuelve todas las respuestas, no las de ese grupo.
- **El orden no sigue el envío:** finaliza tres formularios seguidos; en la lista no aparecen como las tres primeras ni las tres últimas.
- **Ninguna respuesta trae fecha ni nombre.**
- **`withComments=true`:** solo las que tienen comentario, y `totalCount` cambia.

**Excel**
- **Abre sin avisos de reparación** en Excel de escritorio y en Excel web.
- **Tiene las cuatro hojas:**
  - Resumen: cifras, barra de bloques y estrellas.
  - Por grupo: barra de datos de avance.
  - Personas: filtros y estados con color.
  - Respuestas: estrellas, diferencia con escala de color y comentarios con ajuste de texto.
- **Curso sin respuestas suficientes:** el Resumen y la hoja de respuestas muestran "Aún no hay respuestas suficientes… (2 de 3)".
- **Un grupo pequeño:** la hoja de respuestas no tiene la columna "Grupo" y "Por grupo" no muestra las calificaciones.

**PDF**
- **Cabe en una o dos páginas** para un curso de 5 grupos, con el pie "Página 1 de 2".
- **Las barras:**
  - Un grupo al 0 % se ve todo gris.
  - Uno al 100 %, todo amarillo.
- **Sin comentarios:** no aparece la sección "Comentarios".

**Otros**
- **`format=docx`** → 400 "Formato no válido…".
- **Curso que no existe** → 404.

---

## ✅ Checklist

- [ ] `AnonymousResponseRow`, `ResultsPersonRow`, `GetResponsesAsync` y `GetResultsPeopleAsync`.
- [ ] `CourseResultsConstants` y `CourseResultsDtos`.
- [ ] `CourseResultsReport`, `CourseResultsExcelWriter` y `CourseResultsPdfWriter`.
- [ ] `CourseResultsService` y su registro.
- [ ] `CoursesController`: `GetResponses` y `ExportResults`.
- [ ] `ApiResponseConstants`.
- [ ] CORS con `WithExposedHeaders("Content-Disposition")`.
