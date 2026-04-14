import { useState, useEffect } from "react";
import { api, SFObject, SFObjectDetail } from "../../lib/api";

interface FieldSearchProps {
  onSearch: (object: string, field: string) => void;
  initialObject?: string;
  initialField?: string;
}

export function FieldSearch({
  onSearch,
  initialObject,
  initialField,
}: FieldSearchProps) {
  const [objects, setObjects] = useState<SFObject[]>([]);
  const [selectedObject, setSelectedObject] = useState(initialObject || "");
  const [objectDetail, setObjectDetail] = useState<SFObjectDetail | null>(null);
  const [selectedField, setSelectedField] = useState(initialField || "");
  const [objectSearch, setObjectSearch] = useState("");
  const [fieldSearch, setFieldSearch] = useState("");

  useEffect(() => {
    api.getObjects().then(setObjects).catch(console.error);
  }, []);

  useEffect(() => {
    if (selectedObject) {
      api.getObject(selectedObject).then(setObjectDetail).catch(console.error);
    } else {
      setObjectDetail(null);
    }
  }, [selectedObject]);

  useEffect(() => {
    if (initialObject && initialField) {
      onSearch(initialObject, initialField);
    }
  }, []);

  const filteredObjects = objects.filter(
    (o) =>
      o.name.toLowerCase().includes(objectSearch.toLowerCase()) ||
      o.label.toLowerCase().includes(objectSearch.toLowerCase())
  );

  const filteredFields = (objectDetail?.fields || []).filter(
    (f) =>
      f.name.toLowerCase().includes(fieldSearch.toLowerCase()) ||
      f.label.toLowerCase().includes(fieldSearch.toLowerCase())
  );

  const handleSearch = () => {
    if (selectedObject && selectedField) {
      onSearch(selectedObject, selectedField);
    }
  };

  return (
    <div className="space-y-4 rounded-lg border border-border bg-card p-4">
      <div className="grid grid-cols-2 gap-4">
        {/* Object selector */}
        <div className="space-y-2">
          <label className="text-xs font-medium text-muted-foreground">
            Object
          </label>
          <input
            type="text"
            placeholder="Search objects..."
            value={objectSearch}
            onChange={(e) => setObjectSearch(e.target.value)}
            className="w-full rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
          />
          <div className="max-h-48 overflow-auto rounded-lg border border-input">
            {filteredObjects.slice(0, 50).map((obj) => (
              <button
                key={obj.name}
                onClick={() => {
                  setSelectedObject(obj.name);
                  setSelectedField("");
                  setFieldSearch("");
                }}
                className={`w-full px-3 py-1.5 text-left text-sm transition-colors hover:bg-accent/50 ${
                  selectedObject === obj.name
                    ? "bg-accent text-accent-foreground"
                    : "text-foreground"
                }`}
              >
                {obj.label}{" "}
                <span className="text-xs text-muted-foreground">
                  ({obj.name})
                </span>
              </button>
            ))}
          </div>
        </div>

        {/* Field selector */}
        <div className="space-y-2">
          <label className="text-xs font-medium text-muted-foreground">
            Field
          </label>
          <input
            type="text"
            placeholder={
              selectedObject ? "Search fields..." : "Select an object first"
            }
            value={fieldSearch}
            onChange={(e) => setFieldSearch(e.target.value)}
            disabled={!selectedObject}
            className="w-full rounded-lg border border-input bg-background px-3 py-2 text-sm text-foreground placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring disabled:opacity-50"
          />
          <div className="max-h-48 overflow-auto rounded-lg border border-input">
            {filteredFields.map((field) => (
              <button
                key={field.name}
                onClick={() => setSelectedField(field.name)}
                className={`w-full px-3 py-1.5 text-left text-sm transition-colors hover:bg-accent/50 ${
                  selectedField === field.name
                    ? "bg-accent text-accent-foreground"
                    : "text-foreground"
                }`}
              >
                {field.label}{" "}
                <span className="text-xs text-muted-foreground">
                  ({field.name})
                </span>
              </button>
            ))}
            {selectedObject && filteredFields.length === 0 && (
              <div className="px-3 py-2 text-xs text-muted-foreground">
                {objectDetail ? "No fields match" : "Loading fields..."}
              </div>
            )}
          </div>
        </div>
      </div>

      <button
        onClick={handleSearch}
        disabled={!selectedObject || !selectedField}
        className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground transition-colors hover:bg-primary/90 disabled:opacity-50"
      >
        Find Usage
      </button>
    </div>
  );
}
