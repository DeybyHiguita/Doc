# ✉️ Certificados — Correo sin botón ni nota del Portal del Empleado

**Lo que cambia:** el correo de los tres certificados deja de mostrar:
- El botón **"Acceder al Portal del Empleado"**.
- La nota **"Si deseas más detalles o tienes alguna inquietud, puedes consultar toda la información en el Portal del Empleado."**
- La invitación final **"Te invitamos a usar el Portal del Empleado para resolver cualquier duda…"**.

| Certificado | Quién envía el correo |
|---|---|
| Certificado Laboral | `ApproverService.SendChangeStatusEmailNotificationLabor` |
| Cesantías | `ApproverService.SendChangeStatusEmailNotification` |
| Ingresos y Retenciones | `ApproverService.SendIncomeWithholdingEmailAsync` (guía [certificado-ingresos-retenciones-envio-correo.md](certificado-ingresos-retenciones-envio-correo.md)) |

**Las demás solicitudes no cambian:** los permisos y las otras solicitudes siguen mostrando la nota y el botón.

**Base:** el código de `.claude/Certificados API`.

---

## 1. Cómo se hace

Los tres usan `TemplateRequestStatusUser.html`, que también usan las demás solicitudes. Por eso no se borra el bloque, sino que se vuelve un token:

- La nota y el botón pasan a `{PORTAL_SECTION}`.
- La invitación final pasa a `{PORTAL_INVITACION}`.
- Solo las solicitudes que **no** son certificados envían esos tokens.

`MailNotificationService` borra los tokens que no se envían, así que en los certificados no aparece nada. El certificado laboral y el de ingresos y retenciones no necesitan cambios en su código.

---

## 2. Paso 1 — `EmailsTemplate/TemplateRequestStatusUser.html` ✏️

**1. Reemplaza** el `<div>` de la nota y la tabla del botón (desde `<div style="padding-top:14px; color:#333333;">` "Si deseas más detalles…" hasta el cierre de la tabla de `<!-- Botón CTA -->`) por:

```html
                            {PORTAL_SECTION}
```

**2. En `<!-- Mensaje final -->`**, cambia el texto por:

```html
                                Este es un mensaje automático generado por el sistema.{PORTAL_INVITACION}
```

---

## 3. Paso 2 — `Features/MailNotification/Application/Helpers/EmailNotificationHelper.cs` ✏️ — agrega

El HTML que antes estaba fijo en la plantilla, igual que `ESTADO_SECTION` y `MENSAJE_SECTION`:

```csharp
/// <summary>Nota y botón del Portal del Empleado. Los certificados no lo llevan.</summary>
public static string PortalSection(string ctaUrl) => $"""
    <div style="padding-top:14px; color:#333333;">
        Si deseas más detalles o tienes alguna inquietud, puedes consultar toda la información en el Portal del Empleado.
    </div>

    <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin-top:22px;">
        <tr>
            <td align="left">
                <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                    <tr>
                        <td bgcolor="#FFC107" style="border-radius:6px;">
                            <a href="{ctaUrl}" target="_blank"
                               style="display:inline-block; padding:14px 22px; font-size:14px;
                               font-weight:bold; color:#111111; text-decoration:none;">
                                Acceder al Portal del Empleado
                            </a>
                        </td>
                    </tr>
                </table>
            </td>
        </tr>
    </table>
    """;

/// <summary>Cierre del mensaje final (lleva el espacio inicial). Los certificados no lo llevan.</summary>
public const string PortalInvitation =
    " Te invitamos a usar el Portal del Empleado para resolver cualquier duda o consulta relacionada con tu solicitud.";
```

---

## 4. Paso 3 — `ApproverService` ✏️

### `SendChangeStatusEmailNotification` — recibe si es certificado

Lo usan las solicitudes comunes **y** las cesantías.

**1. Firma:** agrega `bool isCertificate` al final.

```csharp
private async Task SendChangeStatusEmailNotification(
    int requestId, string userName, string userEmail, string requestTypeName,
    string? observations, string requestStatus, IUnitOfWork unitOfWork, bool isCertificate)
```

**2. Después de armar `tokens`:**

```csharp
// Los certificados no llevan la nota ni el botón del portal.
if (!isCertificate)
{
    tokens["PORTAL_SECTION"] = EmailNotificationHelper.PortalSection($"{frontendApp}/requests");
    tokens["PORTAL_INVITACION"] = EmailNotificationHelper.PortalInvitation;
}
```

**3. La llamada** (en el cambio de estado, rama `else`):

```csharp
await SendChangeStatusEmailNotification(
    request.Id, request.User.Name, request.User.CorportativeEmail, request.RequestType.Name,
    dto.Comments, request.Status, unitOfWork,
    isCertificate: request.RequestType.Type == ConstantsValues.CertificateRequestType);
```

> Busca si hay otras llamadas a `SendChangeStatusEmailNotification` (por ejemplo, en aprobaciones masivas o por delegado) y pásales el mismo valor.

### `SendChangeStatusEmailNotificationLabor` y `SendIncomeWithholdingEmailAsync` — sin cambios

Son solo de certificados: no envían `PORTAL_SECTION` ni `PORTAL_INVITACION`, así que el correo sale sin la nota ni el botón.

---

## 5. Opcional — el correo de "solicitud recibida" de los certificados

Al crear un certificado, `RequestService` envía `TemplateCertificatesCreatedUser.html`, que solo usan los certificados. Ese correo tiene algo parecido:
- "Puedes hacer seguimiento desde el Portal del Empleado."
- El botón "Ir al Portal del Empleado".

Si también se quita, se borran directamente en la plantilla:
- El `<div>` con "Puedes hacer seguimiento desde el Portal del Empleado.".
- La tabla de `<!-- Botón CTA -->`.

No hay que cambiar código, porque ninguna otra solicitud usa esa plantilla.

---

## 6. Pruebas

- **Certificado laboral:** el correo con el PDF llega sin la nota, sin el botón y con el mensaje final "Este es un mensaje automático generado por el sistema." a secas.
- **Cesantías aprobada:** igual, con su PDF.
- **Ingresos y retenciones:** igual, con su PDF.
- **Un permiso o una solicitud común aprobada o rechazada:** sigue mostrando la nota, el botón (lleva a `/requests`) y la invitación final.
- **Ningún correo muestra un `{TOKEN}` sin reemplazar.**

---

## ✅ Checklist

- [ ] `TemplateRequestStatusUser.html`: `{PORTAL_SECTION}` y `{PORTAL_INVITACION}`.
- [ ] `EmailNotificationHelper.PortalSection` y `PortalInvitation`.
- [ ] `SendChangeStatusEmailNotification` recibe `isCertificate`; todas sus llamadas lo pasan.
- [ ] (Opcional) `TemplateCertificatesCreatedUser.html` sin la nota ni el botón.
