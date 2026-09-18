"""Completa el catálogo español de Dran (priv/gettext/es/LC_MESSAGES/default.po).

Idempotente: para cada msgid presente en ES reescribe el msgstr con la
traducción curada y limpia el flag `fuzzy`. Los msgid que no están en ES se
dejan intactos.
"""
import re
import sys

PO = "priv/gettext/es/LC_MESSAGES/default.po"
EN = "priv/gettext/en/LC_MESSAGES/default.po"

ES = {
    "%{count} page": ("%{count} página", "%{count} páginas"),
    "%{count} table": ("%{count} tabla", "%{count} tablas"),
    "%{count} valid field": ("%{count} campo válido", "%{count} campos válidos"),
    "%{count} workspace": ("%{count} workspace", "%{count} workspaces"),
    "page": ("página", "páginas"),
    "%{count} memories permanently deleted": "%{count} memorias borradas permanentemente",
    "%{percent}% used · %{total}": "%{percent}% usado · %{total}",
    "Access": "Acceso",
    "Editor": "Editor",
    "Viewer": "Lector",
    "read-only": "Solo lectura",
    "Admin: settings and members, plus content.": "Admin: ajustes y miembros, además del contenido.",
    "Curated and smart page lists that update as the workspace changes.": "Listas de páginas curadas e inteligentes que se actualizan a medida que cambia el workspace.",
    "Editor: create and edit pages, no access to settings.": "Editor: crea y edita páginas, sin acceso a los ajustes.",
    "Full-text and semantic search across this workspace's pages.": "Búsqueda de texto completo y semántica en las páginas de este workspace.",
    "Generated reports written from this workspace's content.": "Informes generados a partir del contenido de este workspace.",
    "Log of the recent changes to this workspace's pages.": "Registro de los cambios recientes en las páginas de este workspace.",
    "Owner: settings, members and content.": "Owner: ajustes, miembros y contenido.",
    "Private: only members see this workspace. It is absent from other users' workspace lists.": "Privado: solo los miembros ven este workspace. No aparece en las listas de workspaces de otros usuarios.",
    "Public: every user of this instance can open and read this workspace; only members can edit it.": "Público: cualquier usuario de la instancia puede abrir y leer este workspace; solo los miembros pueden editarlo.",
    "Related pages grouped into themes by the nightly job.": "Páginas relacionadas agrupadas en temas por el job nocturno.",
    "Remove %{user} from this workspace?": "¿Quitar a %{user} de este workspace?",
    "Shown in the workspace switcher, the sidebar and every breadcrumb.": "Se muestra en el selector de workspaces, la barra lateral y las migas de pan.",
    "The relationship map of this workspace's pages.": "El mapa de relaciones de las páginas de este workspace.",
    "The workspace identifier in every URL: /%{slug}/notes, /%{slug}/settings…": "El identificador del workspace en cada URL: /%{slug}/notes, /%{slug}/settings…",
    "Timeline of how this workspace's knowledge grew over time.": "Línea temporal de cómo creció el conocimiento de este workspace.",
    "Turn parts of this workspace on or off. Disabling a feature only removes its entry point — no page, relation or summary is ever deleted.": "Activa o desactiva partes de este workspace. Desactivar una funcionalidad solo quita su punto de entrada: nunca se borra ninguna página, relación o resumen.",
    "Viewer: read pages only.": "Viewer: solo lectura de páginas.",
    "What this workspace is called and who can reach it.": "Cómo se llama este workspace y quién puede acceder a él.",
    "Where users land when they have no last-visited workspace. Forces public visibility, and only one workspace can be the default.": "Dónde aterrizan los usuarios cuando no tienen un último workspace visitado. Fuerza la visibilidad pública, y solo un workspace puede ser el predeterminado.",
    "Who can open this workspace, and with which role.": "Quién puede abrir este workspace y con qué rol.",
    "Adding…": "Añadiendo…",
    "Available types": "Tipos disponibles",
    "Clear": "Limpiar",
    "Date + URL": "Fecha + URL",
    "Empty is fine — the type simply gets no extra fields.": "Vacío está bien — el tipo simplemente no tendrá campos extra.",
    "Enabled": "Activado",
    "Disabled": "Desactivado",
    "English is the default. Your choice is saved to your account and applies to every workspace.": "El inglés es el idioma por defecto. Tu elección se guarda en tu cuenta y aplica a todos los workspaces.",
    "Extra fields the editor renders for this type. One JSON array per field: [type, key, label] with type one of %{types}.": "Campos extra que el editor renderiza para este tipo. Un array JSON por campo: [tipo, clave, etiqueta], con tipo uno de %{types}.",
    'Field %{index}: each field is a JSON array like [\\"text\\", \\"cuisine\\", \\"Cuisine\\"].': 'Campo %{index}: cada campo es un array JSON como ["text", "cuisine", "Cuisine"].',
    "Field %{index}: the key must be a non-empty string.": "Campo %{index}: la clave debe ser una cadena no vacía.",
    "Field %{index}: the label must be a non-empty string.": "Campo %{index}: la etiqueta debe ser una cadena no vacía.",
    "Field %{index}: unknown type %{type}. Allowed types: %{allowed}.": "Campo %{index}: tipo desconocido %{type}. Tipos admitidos: %{allowed}.",
    "Gets its own sidebar section, list, graph colour and editor fields. The four built-in types cannot be redefined.": "Tendrá su propia sección en la barra lateral, su lista, su color en el grafo y sus campos de editor. Los cuatro tipos integrados no se pueden redefinir.",
    "Heroicons name. The “hero-” prefix is added automatically.": "Nombre de Heroicons. El prefijo “hero-” se añade automáticamente.",
    "Hex colour for the graph node, the legend and the type dot.": "Color hex para el nodo del grafo, la leyenda y el punto del tipo.",
    "Identifier used by the API and by filters. Lowercase letters, digits, “_” or “-”.": "Identificador usado por el API y por los filtros. Minúsculas, dígitos, “_” o “-”.",
    "Identity": "Identidad",
    "Interface language for your account.": "Idioma de la interfaz para tu cuenta.",
    "Invalid JSON: %{detail}": "JSON inválido: %{detail}",
    "Language": "Idioma",
    "Language updated": "Idioma actualizado",
    "Load an example:": "Cargar un ejemplo:",
    "Meta fields": "Campos de metadatos",
    "Meta fields must be a JSON array of fields.": "Los campos de metadatos deben ser un array JSON de campos.",
    "New type": "Tipo nuevo",
    "Plural name, used for lists and counters.": "Nombre en plural, usado en listas y contadores.",
    "Presentation": "Presentación",
    "Preview": "Vista previa",
    "Remove the “%{label}” page type? Its pages are kept, but they lose their section and list.": "¿Quitar el tipo de página “%{label}”? Sus páginas se conservan, pero pierden su sección y su lista.",
    "Singular name, used in the sidebar and on buttons.": "Nombre en singular, usado en la barra lateral y en los botones.",
    "Text field": "Campo de texto",
    "URL segment — pages will live at /workspace/%{path}/slug. Must be unique and cannot collide with a reserved route.": "Segmento de URL — las páginas vivirán en /workspace/%{path}/slug. Debe ser único y no puede chocar con una ruta reservada.",
    "Which kinds of page this workspace can hold, and which of them are enabled.": "Qué tipos de página puede contener este workspace y cuáles están activados.",
    "optional": "opcional",
    "%{count} memory facts": "%{count} hechos de memoria",
    '%{count} results for “%{query}” — search covers active facts.': '%{count} resultados para “%{query}” — la búsqueda cubre los hechos activos.',
    "(blank = disabled)": "(vacío = deshabilitado)",
    "API admin token": "Token admin del API",
    "API key access updated": "Acceso de la clave API actualizado",
    "API keys": "Claves API",
    "API not configured": "API no configurada",
    "API unavailable — models cannot be listed. You can still write a manual override, or check DRAN_INFERENCE_API_URL.": "API no disponible — los modelos no pueden listarse. Aún puedes escribir un override manual, o revisa DRAN_INFERENCE_API_URL.",
    "Account settings": "Ajustes de cuenta",
    "Active": "Activo",
    "Add a custom page type": "Añadir un tipo de página personalizado",
    "Add page type": "Añadir tipo de página",
    "Advanced": "Avanzado",
    "Atomic facts shared by %{name}'s workers.": "Hechos atómicos compartidos por los workers de %{name}.",
    "BEAM memory": "Memoria BEAM",
    "Body": "Cuerpo",
    "Clusters of related pages in your brain": "Clusters de páginas relacionadas en tu cerebro",
    "Color": "Color",
    "Configuration": "Configuración",
    "Configured": "Configurada",
    "Connection refused — the server is not responding": "Conexión rechazada — el servidor no responde",
    "Could not save settings": "No se pudieron guardar los ajustes",
    "Could not save the page type": "No se pudo guardar el tipo de página",
    "Could not save the preference": "No se pudo guardar la preferencia",
    "Could not update the access": "No se pudo actualizar el acceso",
    "Create some pages to see your brain's trajectory.": "Crea algunas páginas para ver la trayectoria de tu cerebro.",
    "Database": "Base de datos",
    "Default workspace": "Workspace por defecto",
    "Default workspace (forces public visibility)": "Workspace por defecto (fuerza visibilidad pública)",
    "Default workspace (name)": "Workspace por defecto (nombre)",
    "Default workspace (slug)": "Workspace por defecto (slug)",
    "Default workspace and API admin token — persisted in the database.": "Workspace por defecto y token admin del API — persistidos en la base de datos.",
    "Delete permanently": "Borrar permanentemente",
    "Delete stale": "Borrar obsoletos",
    "Delete this key permanently?": "¿Eliminar esta clave permanentemente?",
    "Delete this workspace?": "¿Eliminar este workspace?",
    "Details": "Detalles",
    "Disabled types are hidden in the web UI and rejected by the agent tools for this context.": "Los tipos deshabilitados se ocultan en la interfaz web y las herramientas de agente los rechazan en este workspace.",
    "Disk": "Disco",
    "Domain not resolved": "Dominio no resuelto",
    "Each key carries its own name — that name is the agent identity used to attribute what it writes — plus its own workspace access matrix (read, or read + write).": "Cada clave lleva su propio nombre — ese nombre es la identidad del agente usada para atribuir lo que escribe — además de su propia matriz de acceso por workspace (lectura, o lectura + escritura).",
    "Edit workspace": "Editar workspace",
    "Effective model for chat and workers. Configure in Admin → Models.": "Modelo efectivo para chat y workers. Configúralo en Admin → Modelos.",
    "Effective model for embeddings. Configure in Admin → Models.": "Modelo efectivo para embeddings. Configúralo en Admin → Modelos.",
    'Enable or disable the brain\'s recurring jobs. The toggle only affects scheduled runs — \\"Run now\\" always executes.': 'Activa o desactiva los jobs recurrentes del cerebro. El toggle afecta solo las corridas programadas — "Correr ahora" siempre ejecuta.',
    "Enable or disable workspace features. Disabled features hide their entry points.": "Activa o desactiva funcionalidades del workspace. Las deshabilitadas ocultan sus puntos de entrada.",
    "Enter a new password": "Ingresa una nueva contraseña",
    "Enter your current password": "Ingresa tu contraseña actual",
    "Features": "Funcionalidades",
    "Filter by status": "Filtrar por estado",
    "Generate token": "Generar token",
    "Generated": "Generada",
    "Growth of your second brain over time": "Crecimiento de tu segundo cerebro en el tiempo",
    "Helpful (+0.05 trust)": "Útil (+0.05 trust)",
    "Helpful feedback received": "Feedback útil recibido",
    "Home": "Inicio",
    "Icon": "Icono",
    "Instance": "Instancia",
    "Instance configuration saved.": "Configuración de instancia guardada.",
    "Invalid slug: use lowercase letters, digits and hyphens.": "Slug inválido: usa minúsculas, dígitos y guiones.",
    "Job failed: %{label}": "Job falló: %{label}",
    "LLM, embeddings": "LLM, embeddings",
    "Label": "Etiqueta",
    "Last run": "Último run",
    "Legacy bearer for the API with full-owner access. Blank = disabled; per-user tokens keep working.": "Bearer legacy para el API con acceso full-owner. Vacío = deshabilitado; los tokens por usuario siguen funcionando.",
    "Log out": "Cerrar sesión",
    "Manage which instance users have access to this workspace.": "Gestiona qué usuarios de la instancia tienen acceso a este workspace.",
    "Mark as stale": "Marcar como obsoleto",
    "Membership updated": "Membresía actualizada",
    "Memory": "Memoria",
    "Memory not found": "Memoria no encontrada",
    "Memory scope": "Alcance de la memoria",
    "Meta fields (JSON, optional)": "Campos de metadatos (JSON, opcional)",
    "Monitoring, instance configuration and environment.": "Monitoreo, configuración de instancia y entorno.",
    "Name is required.": "El nombre es obligatorio.",
    "Never": "Nunca",
    "New %{type}": "Nueva %{type}",
    "New API key": "Nueva clave API",
    "New Page": "Nueva página",
    "No API keys yet — create one to give an agent access to your workspaces.": "Aún no hay claves API — crea una para dar a un agente acceso a tus workspaces.",
    "No memories": "Sin memorias",
    "No pages start with this letter.": "Ninguna página empieza por esta letra.",
    "No plan": "Sin plan",
    "No project": "Sin proyecto",
    "No stale memories to delete": "No hay memorias obsoletas que borrar",
    "No users have access to this workspace yet.": "Todavía no hay usuarios con acceso a este workspace.",
    "No workspace": "Sin workspace",
    "None": "Ninguno",
    "Not authorized.": "No autorizado.",
    "Not configured": "No configurada",
    "Not helpful (−0.10 trust)": "No útil (−0.10 trust)",
    "Offline": "Sin conexión",
    "Only mine": "Solo míos",
    "Options": "Opciones",
    "Page type added": "Tipo de página añadido",
    "Page type removed": "Tipo de página eliminado",
    "Peak pages": "Páginas pico",
    "Peak period": "Período pico",
    "Permanent deletion — cannot be undone": "Borrado permanente — no se puede deshacer",
    "Permanently delete ALL stale memories?": "¿Borrar permanentemente TODAS las memorias obsoletas?",
    "Permanently delete this memory? This cannot be undone.": "¿Borrar permanentemente esta memoria? No se puede deshacer.",
    "Plural": "Plural",
    "R/O": "R/O",
    "R/W": "R/W",
    "Refresh": "Actualizar",
    "Related:": "Relacionados:",
    "Related facts derived automatically (semantic)": "Hechos relacionados derivados automáticamente (semantic)",
    "Remove": "Quitar",
    "Remove from workspace": "Quitar del workspace",
    "Restore": "Restaurar",
    "Results for": "Resultados para",
    "Revoked": "Revocada",
    "Saved queries that auto-update as your brain changes": "Consultas guardadas que se actualizan solas a medida que tu cerebro cambia",
    "Search users by email or name...": "Buscar usuarios por email o nombre...",
    "Search worker memory...": "Buscar en la memoria de los workers...",
    "Select a model": "Selecciona un modelo",
    "Select models for chat and embeddings.": "Selecciona modelos para chat y embeddings.",
    "Share memory between workspace users": "Compartir memoria entre los usuarios del workspace",
    "Share pages between workspace users": "Compartir páginas entre los usuarios del workspace",
    "Share read access": "Compartir lectura",
    "Showing only your memories": "Mostrando solo tus memorias",
    "Showing the whole workspace": "Mostrando todo el workspace",
    "Slug": "Slug",
    "Stale": "Obsoletos",
    "Stop impersonating": "Dejar de impersonar",
    "Switch to read + write": "Cambiar a lectura + escritura",
    "Switch to read only": "Cambiar a solo lectura",
    "Test": "Probar",
    "Test connection": "Probar conexión",
    "Testing...": "Probando...",
    "The current password is incorrect": "La contraseña actual es incorrecta",
    "The key name is required": "El nombre de la clave es obligatorio",
    "The key name is the agent identity: content written with this key is attributed to this name unless the client sends an X-Hermes-Agent header.": "El nombre de la clave es la identidad del agente: el contenido escrito con esta clave se atribuye a este nombre salvo que el cliente envíe una cabecera X-Hermes-Agent.",
    "Timeout — the server took too long": "Timeout — el servidor tardó demasiado",
    "Token generated and copied to the clipboard.": "Token generado y copiado al portapapeles.",
    "Top pages": "Páginas principales",
    "Total pages": "Total de páginas",
    "Trajectory": "Trayectoria",
    "Trust score": "Puntuación de confianza",
    "URL path": "Ruta URL",
    "Uptime": "Tiempo activo",
    "When disabled, each user (and their agents) only sees the facts that belong to them; workspace owners and admins keep the full view.": "Si se desactiva, cada usuario (y sus agentes) ve solo los hechos que le pertenecen; owner y admin del workspace conservan la vista completa.",
    "When disabled, each user only sees the pages that belong to them; the graph only draws visible nodes and edges.": "Si se desactiva, cada usuario ve solo las páginas que le pertenecen; el grafo solo pinta nodos y aristas visibles.",
    "Worker memory": "Memoria de workers",
    "Workers store facts here through the /api/memory API; they appear live.": "Los workers almacenan hechos aquí vía la API /api/memory; aparecerán en vivo.",
    "Workspace name, visibility, and default status.": "Nombre, visibilidad y estado por defecto del workspace.",
    "Workspace not found.": "Workspace no encontrado.",
    'Workspace used when a user has no workspace of their own and no active session. Created on save if it does not exist. Blank = \\"personal\\".': 'Workspace usado cuando un usuario no tiene workspace propio ni sesión activa. Se crea al guardar si no existe. Vacío = "personal".',
    "You are impersonating": "Estás impersonando a",
    "You are not a member of any workspace yet.": "Aún no eres miembro de ningún workspace.",
    "You can only grant access to your own workspaces": "Solo puedes dar acceso a tus propios workspaces",
    "active": "activos",
    "custom": "personalizado",
    "more": "más",
    "score": "puntuación",
    "slug and path are explicit and must be unique in this workspace; a slug cannot repeat a built-in type.": "slug y path son explícitos y deben ser únicos en este workspace; un slug no puede repetir un tipo integrado.",
    "this workspace": "este workspace",
}

STR = re.compile(r'"((?:[^"\\]|\\.)*)"')


def esc(s: str) -> str:
    # A Spanish *value* never contains a literal backslash: if one shows up it
    # means the value was written pre-escaped in ES, which would double-escape
    # and produce an unparseable PO file. Fail loudly instead.
    if "\\" in s:
        raise SystemExit(f"ES value contains a backslash (write it unescaped): {s!r}")
    return s.replace('"', '\\"').replace("\n", "\\n")


def msgid_of(block: str):
    m = re.search(r"^msgid ((?:\"(?:[^\"\\]|\\.)*\"\s*)+)", block, re.M)
    if not m:
        return None
    return "".join(STR.findall(m.group(1)))


def main() -> int:
    txt = open(PO, encoding="utf-8").read()
    blocks = txt.split("\n\n")
    touched = 0
    untranslated = []

    for i, b in enumerate(blocks):
        msgid = msgid_of(b)
        if msgid is None or msgid == "":
            continue

        value = ES.get(msgid)

        if value is not None and "msgid_plural" in b:
            if isinstance(value, tuple):
                # Matches the whole msgstr line plus any continuation lines. The
                # generated value is always single-line, so eating the full line
                # is both simpler and safer than balancing quotes (a previously
                # double-escaped entry leaves trailing junk that a balanced
                # match would not consume).
                b = re.sub(r'^msgstr\[0\] [^\n]*(?:\n"[^\n]*)*', f'msgstr[0] "{esc(value[0])}"', b, flags=re.M)
                b = re.sub(r'^msgstr\[1\] [^\n]*(?:\n"[^\n]*)*', f'msgstr[1] "{esc(value[1])}"', b, flags=re.M)
                touched += 1
        elif isinstance(value, str):
            b = re.sub(r'^msgstr [^\n]*(?:\n"[^\n]*)*', f'msgstr "{esc(value)}"', b, flags=re.M)
            touched += 1

        # ALWAYS clear the fuzzy flag, even for entries the dictionary does not
        # cover: Gettext ignores a fuzzy translation, so leaving one behind means
        # the page falls back to English while the file *looks* translated — and
        # the msgstr a merge leaves there is a fuzzy match against an unrelated
        # entry ("Editor" -> "Editar", "Viewer" -> "Ver"), i.e. plain wrong.
        b = re.sub(r"^#, (.*?), fuzzy$", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, (.*?)fuzzy, ?", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, fuzzy\n", "", b, flags=re.M)

        if value is None and is_untranslated(b):
            untranslated.append(msgid)

        blocks[i] = b

    open(PO, "w", encoding="utf-8").write("\n\n".join(blocks))
    print(f"es: translations written: {touched}")

    if untranslated:
        print(f"es: {len(untranslated)} msgid(s) have NO translation — add them to ES:")
        for msgid in sorted(untranslated):
            print(f"  * {msgid!r}")
        return 1

    print(f"en: {clear_identity_catalog()}")
    return 0


def is_untranslated(block: str) -> bool:
    """True when every msgstr of the entry is empty (singular or plural)."""
    values = re.findall(r'^msgstr(?:\[\d\])? "((?:[^"\\]|\\.)*)"$', block, re.M)
    return bool(values) and all(not v.strip() for v in values)


def clear_identity_catalog() -> str:
    """
    Normaliza el catálogo inglés a una identidad pura.

    El inglés ES el idioma fuente: sus `msgid` ya son el texto que se muestra,
    así que cualquier `msgstr` sobrante — o un `fuzzy` heredado de cuando el
    español era el idioma por defecto — es basura que hay que vaciar. Gettext
    cae al `msgid` cuando el `msgstr` está vacío, que es exactamente lo que
    queremos.
    """
    txt = open(EN, encoding="utf-8").read()
    blocks = txt.split("\n\n")
    cleaned = 0

    for i, b in enumerate(blocks):
        if msgid_of(b) in (None, ""):
            continue
        original = b

        b = re.sub(r'^msgstr\[\d\] (?:"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)', 'msgstr[0] ""', b, flags=re.M)
        b = re.sub(r'^msgstr (?:"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)', 'msgstr ""', b, flags=re.M)
        b = re.sub(r"^#, (.*?), fuzzy$", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, (.*?)fuzzy, ?", r"#, \1", b, flags=re.M)
        b = re.sub(r"^#, fuzzy\n", "", b, flags=re.M)

        # A plural entry must keep one msgstr per plural form (en: two).
        if "msgid_plural" in b:
            b = re.sub(
                r'(msgid_plural (?:"(?:[^"\\]|\\.)*"(?:\n"(?:[^"\\]|\\.)*")*)\n)(?:msgstr\[\d\] ""\n)+',
                r'\1msgstr[0] ""\nmsgstr[1] ""\n',
                b,
            )

        blocks[i] = b
        if b != original:
            cleaned += 1

    open(EN, "w", encoding="utf-8").write("\n\n".join(blocks))
    return f"{cleaned} entries emptied"


if __name__ == "__main__":
    sys.exit(main())
