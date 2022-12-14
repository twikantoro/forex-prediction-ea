//+------------------------------------------------------------------+
//|                                                    StopZones.mq5 |
//|                                  Copyright 2022, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2022, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"

#include <MD5Hash.mqh>

CMD5Hash  md5;

enum enum_middle_price_scan_mode //default outside or zero
  {
   outside_or_zero,
   outside_or_inside,
   outside_or_edge
  };
enum enum_confidence_play //default static confidence
  {
   end_below_predefined_confidence,
   end_below_fifty_percent,
   end_below_opposite_confidence
  };
enum enum_starting_price_mode
  {
   based_on_confidence_full_height,
   based_on_confidence_half_height,
   based_on_static_starting_price
  };

input int EA_Magic = 0;
input double volume = 0.01;
input bool flip = false;
input bool ignore_time = false;
//input enum_starting_price_mode starting_price_mode = based_on_confidence;
input double static_starting_price = 0.5;
input double confidence_threshold = 0.55; //Confidence threshold  (default 0.55)
input bool avoid_exit_in_the_same_box = false;
input enum_middle_price_scan_mode middle_price_scan_mode = outside_or_edge;
input enum_confidence_play confidence_play = end_below_predefined_confidence;
input bool use_slope_for_safer_entry = true;
input int slope_threshold = -10; //Slope threshold (-100 to 100) default -10

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int EXPERT_MAGIC = EA_Magic, positionIndex, nextTurnTime, candlePeriod = Period(), barTime, currentHour, latestTradeDir, minimum_rectangle_width = 2, day_seconds;
bool itsBarTime = false, runonce=false, touched_middle_price;
string ENTER = "\n", temp[32], temp2[16], LABEL_DEFAULT="default", debug_live_stuff[];
double dummy[3] = {1,2,3}, shit[1], coord_y_big, coord_y_small, ask, bid, profit;
int coord_x_big, coord_x_small, spread;
datetime slope_intersections_timestamps[32], lastRecordedFeatureDatetime=0, latestTradeBoxTime=0;
ENUM_TIMEFRAMES timeframe_list[] = {PERIOD_M1, PERIOD_M5, PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1, PERIOD_MN1};
struct Rectangle
  {
   string            name;
   datetime          start_time;
   datetime          end_time;
   double            upper_y;
   double            lower_y;
   int               start_index;
   int               end_index;
   double            loss;
  };
Rectangle rectangles[], rectangles_big[], rectangles_big_big[], latest_rectangle, latest_rectangle_big, latest_rectangle_big_big, rectangles_big_non_duplicating[];
Rectangle walls[];
Rectangle empty_rectangle = {"kosong",0,0,0,0,0,0,0};
color test_color = 0x0000FF;
color red = clrRed;
int filehandle_features, filehandle_prediction, features_id, prediction_id, waiting_time, slope_handle;
double prediction[2], feature0;
string features_hash, feature199;
struct Position
  {
   ulong             ticket;
   int               strategy;
   datetime          start_time;
  };
enum enum_ea_state
  {
   waiting_for_signal,
   waiting_for_slope_to_buy,
   waiting_for_slope_to_sell
  };
enum_ea_state ea_state = waiting_for_signal;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
//---
   if(EXPERT_MAGIC==0)
     {
      EXPERT_MAGIC = (int)(datetime)TimeCurrent();
     }
   refreshNextTurnTime();
   Print("==========");
   Print("ea started");
   Print("==========");

   slope_handle = iCustom(_Symbol,PERIOD_CURRENT,"HandmadeIndicators\\FxckitIndicator",14,PRICE_MEDIAN);

   ChartIndicatorAdd(0,0,iMA(_Symbol,PERIOD_CURRENT,3,0,MODE_SMA,PRICE_MEDIAN));

   ObjectsDeleteAll(0,-1,OBJ_RECTANGLE);
   OnTick();
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
//---
//FileClose(filehandle);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {

// check if algo trading enabled and outside active hour
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      if(!ignore_time)
        {
         if((day_seconds<10*3600 || day_seconds>=19*3600) && getEAPosTotal()==0)
            //check if there's open position in profit or no positions at all
            if((getEAPosTotal()>0 && profit>0) || getEAPosTotal()==0)
              {
               //check if profit
               if(getEAPosTotal()>0 && profit>0)
                  closeAllPositions();
               day_seconds = getCurrentTime()%86400;
               Comment(TimeCurrent());
               return;
              }
        }
     }

// to refresh signals
   refreshSignals();

// comment
   Comment(
      TimeCurrent(), ENTER,
      secondsToReadableTime(day_seconds),ENTER,
      "whhat: ",getSymbolPointDigits(), ENTER,
      "live stuff: ", arrayString_toString(debug_live_stuff), ENTER,
      (int)test_color, ENTER,
      (int)red,ENTER,
      "prediction sell: ", prediction[0], ENTER,
      "prediction buy: ", prediction[1], ENTER,
      feature0, ENTER,
      feature199
   );

// trading decisions
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      if(getEAPosTotal()==0)
        {
         //+------------------------------------------------------------------+
         //|   look for trade opportunities                                   |
         //+------------------------------------------------------------------+
         //while(features_id != prediction_id)
         //  {
         //   //wait until they match
         //   //refreshAndWriteFeatures(true);
         //   Sleep(100);
         //  }
         if(latestTradeBoxTime < latest_rectangle_big.start_time)
           {
            if(features_id == prediction_id)
              {
               double middle_price = (latest_rectangle_big.upper_y + latest_rectangle_big.lower_y)
                                     /2;
               //BUY SIGNAL
               if(prediction[1]>=confidence_threshold)
                 {
                  //waiting for slope
                  if(use_slope_for_safer_entry && ea_state == waiting_for_slope_to_buy)
                     if(iSlope(1)>slope_threshold)
                       {
                        ea_state = waiting_for_signal;
                        makePosition(true);
                        return;
                       }

                  //regular signaling
                  if(ask<middle_price)
                    {
                     if(use_slope_for_safer_entry)
                       {
                        ea_state = waiting_for_slope_to_buy;
                       }
                     else
                       {
                        latestTradeBoxTime = latest_rectangle_big.start_time;
                        makePosition(true);
                       }
                    }
                 }

               //SELL SIGNAL
               if(prediction[0]>=confidence_threshold)
                 {
                  //waiting for slope
                  if(use_slope_for_safer_entry && ea_state == waiting_for_slope_to_sell)
                     if(iSlope(1) < -1*slope_threshold)
                       {
                        ea_state = waiting_for_signal;
                        makePosition(false);
                        return;
                       }

                  //regular signaling
                  if(bid>middle_price)
                    {
                     if(use_slope_for_safer_entry)
                       {
                        ea_state = waiting_for_slope_to_sell;
                       }
                     else
                       {
                        latestTradeBoxTime = latest_rectangle_big.start_time;
                        makePosition(false);
                       }
                    }
                 }

               //no threshold hit
               if(!(prediction[1]>=confidence_threshold) && !(prediction[0]>=confidence_threshold))
                  ea_state = waiting_for_signal;
              }
           }
        }
      else
        {
         //+------------------------------------------------------------------+
         //|   manage opened position                                         |
         //+------------------------------------------------------------------+
         if(avoid_exit_in_the_same_box)
           {
            //if(!(latestTradeBoxTime < latest_rectangle_big.start_time))
            //  {
            //   return;
            //  }
            //check if current or previous
            if(latest_rectangle_big.start_time <= latestTradeBoxTime)
              {
               return;
              }
            //found new box
            else
              {
               //check if prediction agrees with running position
               if((latestTradeDir>0 && prediction[1]>confidence_threshold) || (latestTradeDir<0 && prediction[0]>confidence_threshold))
                 {
                  latestTradeBoxTime = latest_rectangle_big.start_time;
                  return;
                 }
               else
                  closeAllPositions();
                  return;
              }
           }

         //setting confidence
         double modified_confidence_threshold = confidence_threshold;
         switch(confidence_play)
           {
            case end_below_fifty_percent:
               modified_confidence_threshold = 0.5;
               break;
            case end_below_opposite_confidence:
               modified_confidence_threshold = 1-confidence_threshold;
           }

         //long position
         if(latestTradeDir > 0)
           {
            if(prediction[1] >= modified_confidence_threshold)
              {
               //go ahead
               //latestTradeBoxTime = latest_rectangle_big.start_time;
              }
            else
              {
               //terminate
               closeAllPositions();
              }
           }
         //short position
         if(latestTradeDir < 0)
           {
            if(prediction[0] >= modified_confidence_threshold)
              {
               //go ahead
               //latestTradeBoxTime = latest_rectangle_big.start_time;
              }
            else
              {
               //terminate
               closeAllPositions();
              }
           }
        }
     }


  }
//+------------------------------------------------------------------+
//|   refresh signals                                                |
//+------------------------------------------------------------------+
void refreshSignals()
  {
// refresh every tick
   formSquare(TimeCurrent(),"live_rectangle",clrYellow);
   refreshLiveStuff();
   day_seconds = getCurrentTime()%86400;
   refreshAndWriteFeatures();
   if(getEAPosTotal()>0)
     {
      PositionGetTicket(0);
      profit = PositionGetDouble(POSITION_PROFIT);
     }

//refreshSlopeIntersectionTimestamps();
   if(!runonce)
     {
      //formSquare(TimeCurrent());
      //for(int i=0; i<=50; i++)
      //   int hehe = formSquare(iTime(_Symbol,PERIOD_CURRENT,i));
      //runonce=true;
     }

// refresh current hour
   int currentHourTemp = MathFloor(getCurrentTime()%86400/3600);
   currentHour = currentHourTemp;

// refresh every bar
   int currBarTime = iTime(_Symbol,PERIOD_CURRENT,0);
//ObjectsDeleteAll(0,-1,OBJ_RECTANGLE);
   if(currBarTime!=barTime)
     {
      //enter barly command here
      barTime = currBarTime;
      //formSquare(TimeCurrent());
      ArrayFree(rectangles);
      ArrayFree(rectangles_big);
      ArrayFree(rectangles_big_big);
      ObjectsDeleteAll(0,-1,OBJ_RECTANGLE);
      /*
      for(int i=0; i<600; i++)
         int hehe = formSquare(iTime(_Symbol,PERIOD_CURRENT,i));
      //*/

      //draw bigger rectangles
      // declare timeframe
      ENUM_TIMEFRAMES timeframe_big = timeframe_list[getIndexInArrayByValue(timeframe_list,ChartPeriod())+1];
      for(int i=0; i<=50; i++)
        {
         formSquare(iTime(_Symbol,timeframe_big,i),LABEL_DEFAULT,clrDodgerBlue,1);
        }
      refreshBigRectanglesNonDuplicating();
      double middle_price = (latest_rectangle_big.upper_y+latest_rectangle_big.lower_y)/2;
      if(ObjectFind(0,"middle_price")<0)
         ObjectCreate(0,"middle_price",OBJ_TREND,0,latest_rectangle_big.start_time,middle_price,iTime(_Symbol,PERIOD_CURRENT,0),middle_price);

      /*
      //draw bigger rectangles (level 2)
      // declare timeframe
      ENUM_TIMEFRAMES timeframe_big_big = timeframe_list[getIndexInArrayByValue(timeframe_list,ChartPeriod())+2];
      for(int i=0; i<=50; i++)
        {
         formSquare(iTime(_Symbol,timeframe_big_big,i),LABEL_DEFAULT,clrFireBrick,2,3);
        }
      //*/

      //runonce=true;
      tidyUpRectangles(rectangles);
      tidyUpRectangles(rectangles_big);
      tidyUpRectangles(rectangles_big_big);
     }

  }
//+------------------------------------------------------------------+
//|   get slope                                                      |
//+------------------------------------------------------------------+
double iSlope(int index)
  {
   double wtf[];
   CopyBuffer(slope_handle,0,index,1,wtf);
   return wtf[0];
  }
//+------------------------------------------------------------------+
//|   refresh and write features                                     |
//+------------------------------------------------------------------+
void refreshAndWriteFeatures(bool keep_id=false)
  {
// box specification
   double upper_y = latest_rectangle_big.upper_y;
   double lower_y = latest_rectangle_big.lower_y;
   double box_height = upper_y-lower_y;
   double middle_price = (upper_y+lower_y)/2;
// find first occurence of reaching middle price
   int touching_index = 0;
   touched_middle_price = false;
   for(int i=iBarShift(_Symbol,PERIOD_CURRENT,latest_rectangle_big.end_time); i>=0; i--)
     {
      double low = iLow(_Symbol,PERIOD_CURRENT,i);
      double high = iHigh(_Symbol,PERIOD_CURRENT,i);
      if(low<=middle_price && high>=middle_price)
        {
         touching_index = i;
         touched_middle_price = true;
         break;
        }
     }
// find first occurence of reaching middle price INSIDE the box (if enabled)
   if(middle_price_scan_mode == outside_or_inside)
     {
      if(!touched_middle_price)
        {
         Print("middle price is not touched outside the box");
         // find first occurence of reaching middle price INSIDE the box
         for(int i=iBarShift(_Symbol,PERIOD_CURRENT,latest_rectangle_big.end_time); i<iBarShift(_Symbol,PERIOD_CURRENT,latest_rectangle_big.start_time); i++)
           {
            double low = iLow(_Symbol,PERIOD_CURRENT,i);
            double high = iHigh(_Symbol,PERIOD_CURRENT,i);
            if(low<=middle_price && high>=middle_price)
              {
               touching_index = i;
               break;
              }
           }
        }
     }
// if allows edge, use edge
   if(!touched_middle_price && middle_price_scan_mode == outside_or_edge)
     {
      touching_index = iBarShift(_Symbol,PERIOD_CURRENT,latest_rectangle_big.end_time);
     }
// keep id (useful for correcting corrupt features file)
   if(!keep_id)
     {
      int proposed_id = MathRand();
      while(features_id == proposed_id)
        {
         proposed_id = MathRand();
        }
      features_id = proposed_id;
     }


// build features
   string features = "";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      features += NormalizeDouble((iOpen(_Symbol,PERIOD_CURRENT,i)-middle_price)/box_height,5) + ",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      features += NormalizeDouble((iHigh(_Symbol,PERIOD_CURRENT,i)-middle_price)/box_height,5) + ",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      features += NormalizeDouble((iLow(_Symbol,PERIOD_CURRENT,i)-middle_price)/box_height,5) + ",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      features += NormalizeDouble((iClose(_Symbol,PERIOD_CURRENT,i)-middle_price)/box_height,5) + ",";

   feature0 = NormalizeDouble((iOpen(_Symbol,PERIOD_CURRENT,touching_index+1)-middle_price)/box_height,5);
   feature199 = StringSubstr(features,StringLen(features)-9,-1);
// build hash
   uchar bytes[];
   StringToCharArray(features, bytes, 0, StringLen(features)); // transferred string to the byte array // without the last one\0
   string hash = md5.Hash(bytes, ArraySize(bytes));
// add latest box information
   string box_information = "";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      box_information += (int)iTime(_Symbol,PERIOD_CURRENT,i)+",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      box_information += iOpen(_Symbol,PERIOD_CURRENT,i)+",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      box_information += iHigh(_Symbol,PERIOD_CURRENT,i)+",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      box_information += iLow(_Symbol,PERIOD_CURRENT,i)+",";
   for(int i=touching_index+1; i<=touching_index+50; i++)
      box_information += iClose(_Symbol,PERIOD_CURRENT,i)+",";
   box_information += latest_rectangle_big.upper_y+","+latest_rectangle_big.lower_y+","+iBarShift(_Symbol,PERIOD_CURRENT,latest_rectangle_big.start_time)+","+iBarShift(_Symbol,PERIOD_CURRENT,latest_rectangle_big.end_time);
// write to file
   if(features_hash!=hash)
     {
      ObjectCreate(0,"touching_bar_object",OBJ_ARROW_RIGHT_PRICE,0,iTime(_Symbol,PERIOD_CURRENT,touching_index),middle_price);
      ObjectDelete(0,"middle_price");
      ObjectCreate(0,"middle_price",OBJ_TREND,0,latest_rectangle_big.start_time,middle_price,iTime(_Symbol,PERIOD_CURRENT,touching_index),middle_price);
      ResetLastError();
      filehandle_features = FileOpen("box_features.csv",FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
      if(filehandle_features!=INVALID_HANDLE)
        {
         Print("features written, hash renewed. id "+features_id+" touching index "+touching_index);
         features_hash = hash;
         FileWrite(filehandle_features,features_id+"\n"+features+"\n"+hash+"\n"+box_information);
         FileClose(filehandle_features);
         //sekalian baca hasil prediksi
         int result = -1;
         int retries = 0;
         waiting_time = 100;
         while(result<=0)
           {
            //Print("trying again in ",waiting_time,"ms");
            result = obtainPrediction();
            if(result==-99)
              {
               return;
              }
            //Sleep(waiting_time);
            waiting_time = waiting_time*1.1;
            retries++;
           }
         waiting_time = 100;
        }
      else
        {
         //Print("file write error ",GetLastError(),". trying again");
        }
     }
  }
//+------------------------------------------------------------------+
//|   get md5 hash string                                            |
//+------------------------------------------------------------------+
string getMD5HashString(string in)
  {
   uchar bytes[];
   StringToCharArray(in, bytes, 0, StringLen(in)); // transferred string to the byte array // without the last one\0
   string hash = md5.Hash(bytes, ArraySize(bytes));
   return hash;
  }
//+------------------------------------------------------------------+
//|   obtain prediction                                              |
//+------------------------------------------------------------------+
int obtainPrediction()
  {
   string idk = "[READ_PREDICTION:"+features_id+"]";
   ResetLastError();
   filehandle_prediction = FileOpen("box_prediction.csv",FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(filehandle_prediction!=INVALID_HANDLE)
     {
      string firstline = FileReadString(filehandle_prediction);
      //if(firstline == "")
      //  {
      //   refreshAndWriteFeatures(true);
      //   return -99;
      //  }
      int temp_prediction_id = StringToInteger(firstline);
      string prediction_string = FileReadString(filehandle_prediction);
      prediction_string = StringSubstr(prediction_string,0,-3);
      //Print(prediction_string);
      string prediction_hash = FileReadString(filehandle_prediction);
      // matching feature id with newly obtained prediction id
      if(features_id != temp_prediction_id)
        {
         //Print(idk+" prediction id ("+temp_prediction_id+") doesn't match features id");
         FileClose(filehandle_prediction);
         //verify features and rewrite if corrupt
         //refreshAndWriteFeatures(true);
         //return -99;
         return -2;
        }
      // verifying integrity
      string calculated_hash = getMD5HashString(prediction_string);
      //if(calculated_hash != prediction_string)
      //  {
      //   Print(idk+" hash doesn't match");
      //   FileClose(filehandle_prediction);
      //   return -3;
      //  }
      string prediction_array_string[];
      StringSplit(prediction_string,StringGetCharacter(",",0),prediction_array_string);
      double prediction_array_double[] = {StringToDouble(prediction_array_string[0]),StringToDouble(prediction_array_string[1])};
      ArrayCopy(prediction,prediction_array_double);
      prediction_id = temp_prediction_id;

      FileClose(filehandle_prediction);
      return 1;
     }
   else
     {
      //Print(idk+" error opening file. error code "+GetLastError());
      return -1;
     }
  }
//+------------------------------------------------------------------+
//|   refresh non-duplicating-big-rectangles                         |
//+------------------------------------------------------------------+
void refreshBigRectanglesNonDuplicating()
  {
   ArrayFree(rectangles_big_non_duplicating);
   datetime prev_time;
   for(int i=0; i<rectangles_big.Size(); i++)
     {
      Rectangle currBox = rectangles_big[i];
      int size = rectangles_big_non_duplicating.Size();
      if(prev_time>currBox.start_time || (prev_time==0 && size==0))
        {
         //append new one
         ArrayResize(rectangles_big_non_duplicating,size+1);
         rectangles_big_non_duplicating[size] = currBox;
         prev_time = currBox.start_time;
        }
     }
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
string secondsToReadableTime(int seconds)
  {
   return StringFormat("%02d:%02d:%02d",seconds/3600,seconds/60%60,seconds%60);
  }
//+------------------------------------------------------------------+
//|   refresh live stuff                                             |
//+------------------------------------------------------------------+
void refreshLiveStuff()
  {
// ask, bid, two y coords and two x coords and spread
   ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
// latest non-empty rectangles
   for(int i=0; i<ArraySize(rectangles_big); i++)
      if(rectangles_big[i].name!="kosong")
        {
         latest_rectangle_big = rectangles_big[i];
         break;
        }
   for(int i=0; i<ArraySize(rectangles); i++)
      if(rectangles[i].name!="kosong")
        {
         latest_rectangle = rectangles[i];
         break;
        }
// height
   double rect_big_height = latest_rectangle_big.upper_y - latest_rectangle_big.lower_y;
   double rect_small_height = latest_rectangle.upper_y - latest_rectangle.lower_y;
// middle price
   double price_middle = (ask+bid)/2;
// y
   coord_y_big = NormalizeDouble((price_middle-latest_rectangle_big.lower_y)/rect_big_height*100,2);
   coord_y_small = NormalizeDouble((price_middle-latest_rectangle.lower_y)/rect_small_height*100,2);
// x
   coord_x_big = latest_rectangle_big.end_index;
   coord_x_small = latest_rectangle.end_index;
// spread
   spread = iSpread(_Symbol,PERIOD_CURRENT,0);
// for debugging
   string temp_[] = {ask,bid,coord_y_big,coord_y_small,coord_x_big,coord_x_small,spread, NormalizeDouble(rect_big_height*1000,2), NormalizeDouble(rect_small_height*1000,2),
                     latest_rectangle.upper_y, latest_rectangle.lower_y, latest_rectangle.name, latest_rectangle.start_index,latest_rectangle.end_index
                    };
   ArrayCopy(debug_live_stuff,temp_);
  }
//+------------------------------------------------------------------+
//|   refresh walls                                                  |
//+------------------------------------------------------------------+
void refreshWalls()
  {

  }
//+------------------------------------------------------------------+
//|   tidy up rectangles                                             |
//+------------------------------------------------------------------+
void tidyUpRectangles(Rectangle &inp_rectangle[])
  {
// fix overlaps
// loop through rectangles array
   for(int i=0; i<ArraySize(inp_rectangle); i++)
     {
      //store start and end index
      int start_index = inp_rectangle[i].start_index;
      int end_index = inp_rectangle[i].end_index;
      //loop through inp_rectangle array and check if there are overlaps
      //Rectangle inp_rectangle_temp[];
      for(int j=0; j<ArraySize(inp_rectangle); j++)
        {
         int j_start_index = inp_rectangle[j].start_index;
         int j_end_index = inp_rectangle[j].end_index;
         if((j_end_index<start_index && j_end_index>end_index) || (j_start_index>end_index && j_start_index<start_index))
           {
            //overlaps. keep the widest one, then the lowest loss
            int width = start_index-end_index;
            int j_width = j_start_index-j_end_index;
            if(width==0 || j_width==0)
               break;
            if(width!=j_width)
               //one must be deleted
               if(width>j_width)
                  //delete competitor (j)
                  deleteRectangleByIndexAndArray(j, inp_rectangle);
               else
                 {
                  //delete current rectangle and stop iteration
                  deleteRectangleByIndexAndArray(i, inp_rectangle);
                  break;
                 }
            else
               //keep the lowest loss
               if(inp_rectangle[i].loss<inp_rectangle[j].loss)
                  deleteRectangleByIndexAndArray(j,inp_rectangle);
               else
                 {
                  deleteRectangleByIndexAndArray(i,inp_rectangle);
                  break;
                 }
           }
        }
     }

//remove rectangles with width 2 that doesnt have neighbors (later, maybe, idk if it's a good idea)
  }
//+------------------------------------------------------------------+
//|   delete rectangle by index                                      |
//+------------------------------------------------------------------+
void deleteRectangleByIndexAndArray(int i, Rectangle &rectangle_array[])
  {
   ResetLastError();
   bool deletion = ObjectDelete(0,rectangle_array[i].name);
   if(!deletion)
      Print("delete error ",GetLastError()," index ", i," start index ",rectangle_array[i].start_index);
   rectangle_array[i] = empty_rectangle;
  }
//+------------------------------------------------------------------+
//|   get index in array by value                                    |
//+------------------------------------------------------------------+
int getIndexInArrayByValue(ENUM_TIMEFRAMES &inp_arr[], ENUM_TIMEFRAMES inp_value)
  {
   int out_index = -1;
   for(int i = 0; i<ArraySize(inp_arr); i++)
     {
      if(inp_arr[i]==inp_value)
        {
         out_index=i;
         break;
        }
     }
   return out_index;
  }
//+------------------------------------------------------------------+
//|   form square (input: candle timestamp)                          |
//+------------------------------------------------------------------+
int formSquare(datetime timestamp, string label="default", color warna=clrAqua, int size=0, int thickness=1)
  {
// identify current timeframe's index
   int index_of_timeframe = getIndexInArrayByValue(timeframe_list,ChartPeriod());

// define default rectangle label
   string label_prefix[] = {"rectangle_","rectangle_big_","rectangle_big_big_"};
   if(label==LABEL_DEFAULT)
      label = label_prefix[size]+(int)timestamp;

// declare timeframe
   ENUM_TIMEFRAMES timeframe = timeframe_list[index_of_timeframe+size];

//Print("forming square with timestamp ",timestamp);
// convert timestamp to index
   int barIndex = iBarShift(_Symbol,timeframe,timestamp);
// square specifications: upperline_price, bottomline_price, leftline_timestamp, rightline_timestamp
// what to loop
// - loop while increasing candle count
// - loop through each combination. calculate loss. later we find excluded neighbor's weight
// - loop through dots
   int candle_count = 1;
   bool satisfied = false;
   double rectangle_losses[], rectangle_upper_ys[], rectangle_lower_ys[], rectangle_side_losses[];
   int rectangle_start_indexes[], rectangle_end_indexes[];
// loop while increasing candle count to find best width with the lowest loss, rectangle parameters included
   while(!satisfied)
     {
      //Print("=== NEW WIDTH: ",candle_count," ===");
      //expand arrays according to width
      ArrayResize(rectangle_losses,candle_count);
      ArrayResize(rectangle_start_indexes,candle_count);
      ArrayResize(rectangle_end_indexes,candle_count);
      ArrayResize(rectangle_upper_ys,candle_count);
      ArrayResize(rectangle_lower_ys,candle_count);
      ArrayResize(rectangle_side_losses,candle_count);

      //variables to keep in current width
      double combination_losses[], combination_upper_ys[], combination_lower_ys[], combination_side_losses[];
      int combination_start_indexes[], combination_end_indexes[];
      ArrayResize(combination_losses,candle_count);
      ArrayResize(combination_upper_ys,candle_count);
      ArrayResize(combination_lower_ys,candle_count);
      ArrayResize(combination_start_indexes, candle_count);
      ArrayResize(combination_end_indexes, candle_count);
      ArrayResize(combination_side_losses,candle_count);
      //loop through each combination to calculate ys and losses, so we can select one with the lowest loss, start and end index included
      for(int i=0; i<candle_count; i++)
        {
         //variables to keep in this combination
         int start_index = barIndex+candle_count-i-1;
         int end_index = start_index-candle_count+1;
         double upper_dots[], lower_dots[];
         ArrayResize(upper_dots,candle_count);
         ArrayResize(lower_dots,candle_count);
         //loop through each dots to keep their price levels
         for(int j = 0; j<candle_count; j++)
           {
            //save dots
            upper_dots[j] = iHigh(_Symbol,timeframe,start_index-j);
            lower_dots[j] = iLow(_Symbol,timeframe,start_index-j);
            //debugging
            ////Print(start_index,",",start_index-j,arrayDoubleToString(upper_dots),arrayDoubleToString(lower_dots));
           }
         //calculate price best fit (upper line)
         double dots_max = arrayMaxVal(upper_dots);
         double dots_min = arrayMinVal(upper_dots);
         double total_distance_from_min = 0;
         //get total distance from min
         for(int j=0; j<candle_count; j++)
            total_distance_from_min += upper_dots[j]-dots_min;
         //calculate best_fit
         double best_fit = dots_min+(total_distance_from_min/candle_count);
         double upper_loss = 0;
         //calculate loss
         for(int j=0; j<candle_count; j++)
            upper_loss += MathAbs(upper_dots[j]-best_fit);
         //calculate price best fit (lower line)
         double lower_dots_max = arrayMaxVal(lower_dots);
         double lower_dots_min = arrayMinVal(lower_dots);
         double total_distance_from_lower_min = 0;
         //get total distance from min
         for(int j=0; j<candle_count; j++)
            total_distance_from_lower_min += lower_dots[j]-lower_dots_min;
         //calculate best fit
         double lower_best_fit = lower_dots_min+(total_distance_from_lower_min/candle_count);
         double lower_loss = 0;
         //calculate loss
         for(int j=0; j<candle_count; j++)
            lower_loss += MathAbs(lower_dots[j]-lower_best_fit);

         //side loss normalization factor
         double normalization_factor = candle_count>1 ? (rectangle_upper_ys[0]-rectangle_lower_ys[0])/(best_fit-lower_best_fit) : 1;

         //calculate loss with neighboring candles (left side), normalized as if the rectangle height is same as the first iteration
         double left_loss = calculateLeftLoss(start_index,best_fit,lower_best_fit,size)*normalization_factor;
         //calculate loss with neighboring candles (right side), normalized as if the rectangle height is same as the first iteration
         double right_loss = calculateRightLoss(end_index,best_fit,lower_best_fit,size)*normalization_factor;

         //assign variables
         combination_losses[i] = upper_loss + lower_loss + left_loss + right_loss;
         combination_upper_ys[i] = best_fit;
         combination_lower_ys[i] = lower_best_fit;
         combination_start_indexes[i] = start_index;
         combination_end_indexes[i] = end_index;
         combination_side_losses[i] = left_loss+right_loss;
        }
      //find combination with the lowest loss and assign
      int best_index = ArrayMinimum(combination_losses);
      rectangle_losses[candle_count-1] = combination_losses[best_index];
      rectangle_start_indexes[candle_count-1] = combination_start_indexes[best_index];
      rectangle_end_indexes[candle_count-1] = combination_end_indexes[best_index];
      rectangle_upper_ys[candle_count-1] = combination_upper_ys[best_index];
      rectangle_lower_ys[candle_count-1] = combination_lower_ys[best_index];
      rectangle_side_losses[candle_count-1] = combination_side_losses[best_index];

      //check if satisfied
      if(candle_count>1)
        {
         //if(rectangle_losses[candle_count-1]>rectangle_losses[candle_count-2])
         if(arrayMinVal(combination_side_losses)<=0)
           {
            satisfied = true;
            int rectangle_best_index = ArrayMinimum(rectangle_losses);
            int rectangle_start_index = rectangle_start_indexes[rectangle_best_index];
            int rectangle_end_index = rectangle_end_indexes[rectangle_best_index];
            datetime mulai = iTime(_Symbol,timeframe,rectangle_start_index);
            datetime akhir = iTime(_Symbol,timeframe,rectangle_end_index);

            if(rectangle_start_index>rectangle_end_index+minimum_rectangle_width-2)
              {
               //for debugging
               string fordebugging[] = {0,label,OBJ_RECTANGLE,0,
                                        mulai,
                                        rectangle_upper_ys[rectangle_best_index],
                                        akhir,
                                        rectangle_lower_ys[rectangle_best_index]
                                       };
               //Print("specs ",arrayString_toString(fordebugging));

               //saving rectangle specifications
               Rectangle rectangle_temp = {label,
                                           mulai,
                                           akhir,
                                           rectangle_upper_ys[rectangle_best_index],
                                           rectangle_lower_ys[rectangle_best_index],
                                           rectangle_start_index,
                                           rectangle_end_index,
                                           rectangle_losses[rectangle_best_index]
                                          };
               //if bigger, store to bigger array
               switch(size)
                 {
                  case 1:
                     ArrayResize(rectangles_big,ArraySize(rectangles_big)+1);
                     rectangles_big[ArraySize(rectangles_big)-1] = rectangle_temp;
                     break;
                  case 2:
                     ArrayResize(rectangles_big_big,ArraySize(rectangles_big_big)+1);
                     rectangles_big_big[ArraySize(rectangles_big_big)-1] = rectangle_temp;
                     break;
                  default:
                     ArrayResize(rectangles,ArraySize(rectangles)+1);
                     rectangles[ArraySize(rectangles)-1] = rectangle_temp;
                     break;
                 }

               //drawing the rectangle
               ObjectCreate(0,label,OBJ_RECTANGLE,0,
                            mulai,
                            rectangle_upper_ys[rectangle_best_index],
                            akhir,
                            rectangle_lower_ys[rectangle_best_index]
                           );
               ObjectSetInteger(0,label,OBJPROP_COLOR,warna);
               ObjectSetInteger(0,label,OBJPROP_WIDTH,thickness);
              }
            else
              {
               //Print("only has width of one");
              }
           }
        }
      candle_count++;
     }
   return 1;
  }
//+------------------------------------------------------------------+
//|   calculate left loss                                            |
//+------------------------------------------------------------------+
double calculateLeftLoss(int index, double upper_y, double lower_y, int size=0)
  {
// identify current timeframe's index
   int index_of_timeframe = getIndexInArrayByValue(timeframe_list,ChartPeriod());

// declare timeframe
   ENUM_TIMEFRAMES timeframe = timeframe_list[index_of_timeframe+size];

   int end_index = index, array_size=1;
   double reductions[], rectangle_height = upper_y-lower_y, combined_losses[], total_loss=0;
// loop until high is lower than lower_y or low is higher than upper_y. save the index. sambil ngetung reduction yo apik
   for(int i=index+1; i<index+50; i++)
     {
      double high = iHigh(_Symbol,timeframe,i);
      double low = iLow(_Symbol,timeframe,i);
      //calculate reduction
      ArrayResize(reductions,array_size);
      ArrayResize(combined_losses,array_size);
      //top reduction
      double top_reduction = high<upper_y && high>lower_y ? upper_y-high : 0;
      top_reduction = high<lower_y ? rectangle_height : top_reduction;
      //bottom reduction
      double bottom_reduction = low<upper_y && low>lower_y ? low-lower_y : 0;
      bottom_reduction = low>upper_y ? rectangle_height : top_reduction;
      //total reduction
      double total_reduction = top_reduction + bottom_reduction;
      total_reduction = total_reduction>rectangle_height ? rectangle_height : total_reduction;
      //assignment
      reductions[array_size-1] = total_reduction;
      total_loss += rectangle_height-total_reduction;
      combined_losses[array_size-1] = rectangle_height-total_reduction;

      //check if fully reducted
      if(total_reduction>=rectangle_height)
        {
         end_index = i;
         //debugging
         //Print("end index ",i);
         //Print("losses left ",arrayDoubleToString(combined_losses));
         break;
        }
      array_size++;
     }
   return total_loss;
  }
//+------------------------------------------------------------------+
//|   calculate right loss                                           |
//+------------------------------------------------------------------+
double calculateRightLoss(int index, double upper_y, double lower_y, int size=0)
  {
// identify current timeframe's index
   int index_of_timeframe = getIndexInArrayByValue(timeframe_list,ChartPeriod());

// declare timeframe
   ENUM_TIMEFRAMES timeframe = timeframe_list[index_of_timeframe+size];

   int end_index = index, array_size=1;
   double reductions[], rectangle_height = upper_y-lower_y, combined_losses[], total_loss=0;
// loop until high is lower than lower_y or low is higher than upper_y. save the index. sambil ngetung reduction yo apik
   for(int i=index-1; i>index-50 && i>=0; i--)
     {
      double high = iHigh(_Symbol,timeframe,i);
      double low = iLow(_Symbol,timeframe,i);
      //calculate reduction
      ArrayResize(reductions,array_size);
      ArrayResize(combined_losses,array_size);
      //top reduction
      double top_reduction = high<upper_y && high>lower_y ? upper_y-high : 0;
      top_reduction = high<lower_y ? rectangle_height : top_reduction;
      //bottom reduction
      double bottom_reduction = low<upper_y && low>lower_y ? low-lower_y : 0;
      bottom_reduction = low>upper_y ? rectangle_height : top_reduction;
      //total reduction
      double total_reduction = top_reduction + bottom_reduction;
      total_reduction = total_reduction>rectangle_height ? rectangle_height : total_reduction;
      //assignment
      reductions[array_size-1] = total_reduction;
      total_loss += rectangle_height-total_reduction;
      combined_losses[array_size-1] = total_loss;

      //check if fully reducted
      if(total_reduction>=rectangle_height)
        {
         end_index = i;
         //debugging
         //Print("end index ",i);
         //Print("losses right ",arrayDoubleToString(combined_losses));
         break;
        }
      array_size++;
     }
   return total_loss;
  }
//+------------------------------------------------------------------+
//|   rgb to color (bgr)                                             |
//+------------------------------------------------------------------+
uint RGBToColor()
  {
//uchar
   return 0;
  }
//+------------------------------------------------------------------+
//|   array string to string                                         |
//+------------------------------------------------------------------+
string arrayString_toString(string &inparr[])
  {
   string out = "[";
   for(int i = 0; i<ArraySize(inparr); i++)
     {
      out += inparr[i];
      if(i<ArraySize(inparr)-1 && StringLen(inparr[i])>0)
         out+=", ";
     }
   out+="]";
   return out;
  }
//+------------------------------------------------------------------+
//|   array double to string                                         |
//+------------------------------------------------------------------+
string arrayDoubleToString(double &inparr[])
  {
   string out = "[";
   for(int i = 0; i<ArraySize(inparr); i++)
     {
      out += inparr[i];
      if(i<ArraySize(inparr)-1)
         out+=", ";
     }
   out+="]";
   return out;
  }
//+------------------------------------------------------------------+
//|   array integer to string                                        |
//+------------------------------------------------------------------+
string arrayIntegerToString(int &inparr[])
  {
   string out = "[";
   for(int i = 0; i<ArraySize(inparr); i++)
     {
      out += inparr[i];
      if(i<ArraySize(inparr)-1)
         out+=", ";
     }
   out+="]";
   return out;
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int getSymbolPointDigits()
  {
   int digits = 0;
   double becoming_one = Point();
   while(becoming_one<1)
     {
      becoming_one = becoming_one*10;
      digits++;
     }
   return digits;
  }
//+------------------------------------------------------------------+
//|   array get max                                                  |
//+------------------------------------------------------------------+
double arrayMaxVal(double &in[])
  {
   int index = ArrayMaximum(in);
   return in[index];
  }
//+------------------------------------------------------------------+
//|   array get min                                                  |
//+------------------------------------------------------------------+
double arrayMinVal(double &in[])
  {
   int index = ArrayMinimum(in);
   return in[index];
  }
//+------------------------------------------------------------------+
int getCurrentTime()
  {
   return (int)(datetime) TimeCurrent();
  }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void refreshNextTurnTime()
  {
   nextTurnTime = (int) MathRound((double) getCurrentTime() / (candlePeriod * 60)) * candlePeriod * 60;
   if(nextTurnTime < getCurrentTime())
     {
      nextTurnTime += candlePeriod * 60;
     }
  }
//+------------------------------------------------------------------+
int getEAPosTotal()
  {
   int total = PositionsTotal();
   int result = 0;
   for(int i = 0; i<total; i++)
     {
      PositionGetTicket(i);
      int magic = PositionGetInteger(POSITION_MAGIC);
      if(magic == EXPERT_MAGIC)
        {
         positionIndex = i;
         result++;
        }
     }
   return result;
  }
//+------------------------------------------------------------------+
void makePosition(bool directionUp, double takeProfit = 0, double stopLoss = 0)
  {
   latestTradeDir = directionUp ? 1 : -1;
   MqlTradeRequest request =
     {
      TRADE_ACTION_DEAL
     };
   MqlTradeResult result =
     {
      TRADE_ACTION_DEAL
     };
//--- parameters of request
   request.action = TRADE_ACTION_DEAL; // type of trade operation
   request.symbol = Symbol(); // symbol
   request.volume = volume;
   request.type = directionUp ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = SymbolInfoDouble(Symbol(), directionUp ? SYMBOL_ASK : SYMBOL_BID);
   request.deviation = 5; // allowed deviation from the price
   request.magic = EXPERT_MAGIC; // MagicNumber of the order
//request.sl
   if(stopLoss>0)
      request.sl = stopLoss;
//request.tp
   if(takeProfit>0)
      request.tp = takeProfit;

   if(!OrderSend(request, result))
      PrintFormat("OrderSend error %d", GetLastError()); // if unable to send the request, output the error code


//--- information about the operation
   PrintFormat("retcode=%u  deal=%I64u  order=%I64u", result.retcode, result.deal, result.order);
  }
//+------------------------------------------------------------------+
void closeAllPositions()
  {
//--- declare and initialize the trade request and result of trade request
   MqlTradeRequest request;
   MqlTradeResult result;
   int total = PositionsTotal(); // number of open positions
//--- iterate over all open positions
   for(int i = total - 1; i >= 0; i--)
     {
      //--- parameters of the order
      ulong position_ticket = PositionGetTicket(i); // ticket of the position
      string position_symbol = PositionGetString(POSITION_SYMBOL); // symbol
      int digits = (int) SymbolInfoInteger(position_symbol, SYMBOL_DIGITS); // number of decimal places
      ulong magic = PositionGetInteger(POSITION_MAGIC); // MagicNumber of the position
      double volume = PositionGetDouble(POSITION_VOLUME); // volume of the position
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE) PositionGetInteger(POSITION_TYPE); // type of the position
      if(magic == EXPERT_MAGIC)
        {
         //--- zeroing the request and result values
         ZeroMemory(request);
         ZeroMemory(result);
         //--- setting the operation parameters
         request.action = TRADE_ACTION_DEAL; // type of trade operation
         request.position = position_ticket; // ticket of the position
         request.symbol = position_symbol; // symbol
         request.volume = volume; // volume of the position
         request.deviation = 5; // allowed deviation from the price
         request.magic = EXPERT_MAGIC; // MagicNumber of the position
         //--- set the price and order type depending on the position type
         if(type == POSITION_TYPE_BUY)
           {
            request.price = SymbolInfoDouble(position_symbol, SYMBOL_BID);
            request.type = ORDER_TYPE_SELL;
           }
         else
           {
            request.price = SymbolInfoDouble(position_symbol, SYMBOL_ASK);
            request.type = ORDER_TYPE_BUY;
           }
         //--- output information about the closure
         PrintFormat("Close #%I64d %s %s", position_ticket, position_symbol, EnumToString(type));
         //--- send the request
         if(!OrderSend(request, result))
            PrintFormat("OrderSend error %d", GetLastError()); // if unable to send the request, output the error code

         //--- information about the operation
         PrintFormat("retcode=%u  deal=%I64u  order=%I64u", result.retcode, result.deal, result.order);
         //---
        }
     }
  }
//+------------------------------------------------------------------+
void updateStopLossAll()
  {
//--- declare and initialize the trade request and result of trade request
   MqlTradeRequest request;
   MqlTradeResult  result;
   int total=PositionsTotal(); // number of open positions
//--- iterate over all open positions
   for(int i=0; i<total; i++)
     {
      //--- parameters of the order
      ulong  position_ticket=PositionGetTicket(i);// ticket of the position
      string position_symbol=PositionGetString(POSITION_SYMBOL); // symbol
      int    digits=(int)SymbolInfoInteger(position_symbol,SYMBOL_DIGITS); // number of decimal places
      ulong  magic=PositionGetInteger(POSITION_MAGIC); // MagicNumber of the position
      double volume=PositionGetDouble(POSITION_VOLUME);    // volume of the position
      double sl=PositionGetDouble(POSITION_SL);  // Stop Loss of the position
      double tp=PositionGetDouble(POSITION_TP);  // Take Profit of the position
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);  // type of the position

      if(magic==EXPERT_MAGIC && tp==0)
        {
         //--- calculate the current price levels
         double price=PositionGetDouble(POSITION_PRICE_OPEN);
         double bid=SymbolInfoDouble(position_symbol,SYMBOL_BID);
         double ask=SymbolInfoDouble(position_symbol,SYMBOL_ASK);
         //int    stop_level=(int)SymbolInfoInteger(position_symbol,SYMBOL_TRADE_STOPS_LEVEL);
         //double price_level;

         //--- zeroing the request and result values
         ZeroMemory(request);
         ZeroMemory(result);
         //--- setting the operation parameters
         request.action  =TRADE_ACTION_SLTP; // type of trade operation
         request.position=position_ticket;   // ticket of the position
         request.symbol=position_symbol;     // symbol
         //request.tp      =tp;                // Take Profit of the position
         request.magic=EXPERT_MAGIC;         // MagicNumber of the position
         //--- output information about the modification
         PrintFormat("Modify #%I64d %s %s",position_ticket,position_symbol,EnumToString(type));
         //--- send the request
         if(!OrderSend(request,result))
            PrintFormat("OrderSend error %d",GetLastError());  // if unable to send the request, output the error code
         //--- information about the operation
         PrintFormat("retcode=%u  deal=%I64u  order=%I64u",result.retcode,result.deal,result.order);
        }
     }
  }
//+------------------------------------------------------------------+
