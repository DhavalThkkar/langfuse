import type { ColumnDefinition } from "@langfuse/shared";

interface CategoricalFacet {
  type: "categorical";
  column: string;
  label: string;
}

interface BooleanFacet {
  type: "boolean";
  column: string;
  label: string;
  trueLabel?: string;
  falseLabel?: string;
}

interface NumericFacet {
  type: "numeric";
  column: string;
  label: string;
  min: number;
  max: number;
  step?: number;
  unit?: string;
}

interface StringFacet {
  type: "string";
  column: string;
  label: string;
}

interface KeyValueFacet {
  type: "keyValue";
  column: string;
  label: string;
  keyOptions?: string[];
}

interface NumericKeyValueFacet {
  type: "numericKeyValue";
  column: string;
  label: string;
  keyOptions?: string[];
}

interface StringKeyValueFacet {
  type: "stringKeyValue";
  column: string;
  label: string;
  keyOptions?: string[];
}

interface PositionInTraceFacet {
  type: "positionInTrace";
  column: string;
  label: string;
}

export type Facet =
  | CategoricalFacet
  | BooleanFacet
  | NumericFacet
  | StringFacet
  | KeyValueFacet
  | NumericKeyValueFacet
  | StringKeyValueFacet
  | PositionInTraceFacet;

export interface FilterConfig {
  tableName: string;
  columnDefinitions: ColumnDefinition[];
  defaultExpanded?: string[];
  defaultSidebarCollapsed?: boolean;
  facets: Facet[];
}
