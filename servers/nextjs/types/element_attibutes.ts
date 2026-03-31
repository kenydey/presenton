import { ElementHandle } from "puppeteer";

export interface ElementAttributes {
  tagName: string;
  id?: string;
  className?: string;
  innerText?: string;
  /**
   * Parsed HTML table data (thead/tbody) when exporting native PPTX table.
   * When present, the exporter should not screenshot the <table>.
   */
  tableData?: {
    columns: string[];
    rows: string[][];
  };
  /**
   * Parsed chart config/data when exporting native PPTX chart.
   * When present, the exporter should not screenshot the internal <svg>/<canvas>.
   */
  chartData?: {
    chartType: string;
    categories: string[];
    series: Array<{
      name: string;
      values: number[];
    }>;
    showLegend?: boolean;
    showLabels?: boolean;
    colors?: string[];
  };
  opacity?: number;
  background?: {
    color?: string;
    opacity?: number;
  };
  border?: {
    color?: string;
    width?: number;
    opacity?: number;
  };
  shadow?: {
    offset?: [number, number];
    color?: string;
    opacity?: number;
    radius?: number;
    angle?: number;
    spread?: number;
    inset?: boolean;
  },
  font?: {
    name?: string;
    size?: number;
    weight?: number;
    color?: string;
    italic?: boolean;
  };
  position?: {
    left?: number;
    top?: number;
    width?: number;
    height?: number;
  };
  margin?: {
    top?: number;
    bottom?: number;
    left?: number;
    right?: number;
  };
  padding?: {
    top?: number;
    bottom?: number;
    left?: number;
    right?: number;
  };
  zIndex?: number;
  textAlign?: 'left' | 'center' | 'right' | 'justify';
  lineHeight?: number;
  borderRadius?: number[];
  imageSrc?: string;
  objectFit?: 'contain' | 'cover' | 'fill';
  clip?: boolean;
  overlay?: string;
  shape?: 'rectangle' | 'circle';
  connectorType?: string;
  textWrap?: boolean;
  should_screenshot?: boolean;
  element?: ElementHandle<Element>;
  filters?: {
    invert?: number;
    brightness?: number;
    contrast?: number;
    saturate?: number;
    hueRotate?: number;
    blur?: number;
    grayscale?: number;
    sepia?: number;
    opacity?: number;
  };
}

export interface SlideAttributesResult {
  elements: ElementAttributes[];
  backgroundColor?: string;
  speakerNote?: string;
}